import Foundation

/// The National Pokédex (1-649) as Capsule sees it: every species in the bank or in a PC box
/// of one of the games. Shared with the web page through the account (users/UID/meta/pokedex).
@MainActor
final class PokedexStore: ObservableObject {
    static let maxDex = 649
    static let regions: [(name: String, range: ClosedRange<Int>)] = [
        ("Kanto", 1...151), ("Johto", 152...251), ("Hoenn", 252...386), ("Sinnoh", 387...493), ("Unys", 494...649),
    ]

    struct Record: Equatable {
        var bank = 0
        var bankShiny = false
        /// Game name → how many in its boxes.
        var games: [String: Int] = [:]
        var gameShiny = false

        var shiny: Bool { bankShiny || gameShiny }
    }

    @Published private(set) var records: [Int: Record] = [:]
    @Published private(set) var scanning = false

    /// What each game's boxes held, by save file date (scanning a GBA game reads its ROM).
    private struct GameScan: Codable, Equatable {
        var saveDate: Date
        var mons: [[Int]] // [dex, shiny 0/1]
    }
    private var scans: [String: GameScan] = [:]
    private let cacheURL = Storage.bank.appendingPathComponent("pokedex-jeux.json")

    init() {
        if let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode([String: GameScan].self, from: data) {
            scans = saved
        }
    }

    var caught: Int { records.count }

    func record(_ dex: Int) -> Record? { records[dex] }

    // MARK: - Building

    func refresh(bank: BankStore, games: [Game]) async {
        scanning = true
        defer { scanning = false }
        var newScans: [String: GameScan] = [:]
        for game in games where game.supportsPokemonTools && game.hasSave {
            let date = (try? game.saveURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let known = scans[game.name], known.saveDate == date {
                newScans[game.name] = known
                continue
            }
            let mons = await Task.detached(priority: .utility) { Self.scan(game) }.value
            newScans[game.name] = GameScan(saveDate: date, mons: mons)
        }
        if newScans != scans {
            scans = newScans
            if let data = try? JSONEncoder().encode(scans) {
                try? data.write(to: cacheURL, options: .atomic)
            }
        }

        var built: [Int: Record] = [:]
        for entry in bank.entries where !entry.isEgg {
            guard let dex = TradeEvolution.nationalDex(of: entry), (1...Self.maxDex).contains(dex) else { continue }
            built[dex, default: Record()].bank += 1
            if entry.isShiny { built[dex]?.bankShiny = true }
        }
        for (name, scan) in scans {
            for mon in scan.mons where mon.count == 2 && (1...Self.maxDex).contains(mon[0]) {
                built[mon[0], default: Record()].games[name, default: 0] += 1
                if mon[1] == 1 { built[mon[0]]?.gameShiny = true }
            }
        }
        if built != records {
            records = built
        }
    }

    /// Species in a game's PC boxes: [dex, shiny].
    nonisolated private static func scan(_ game: Game) -> [[Int]] {
        let storage: PCStorage
        var rom: RomData?
        do {
            if game.isDS {
                storage = try NDSSaveFile(url: game.saveURL, sourceGame: game.name)
            } else if game.romURL.pathExtension.lowercased() == "gba" {
                let save = try SaveFile(url: game.saveURL)
                rom = RomData.load(game.romURL)
                save.rom = rom
                storage = save
            } else {
                storage = try GBSaveFile(url: game.saveURL, sourceGame: game.name)
            }
        } catch {
            return []
        }
        var result: [[Int]] = []
        for box in 0..<storage.boxCount {
            for mon in storage.listMons(inBox: box) where !mon.isEgg {
                var dex = mon.species
                if storage.generation == 3 {
                    guard let number = rom?.nationalDex(species: mon.species) ?? (mon.species <= 251 ? mon.species : nil) else { continue }
                    dex = number
                }
                result.append([dex, mon.isShiny ? 1 : 0])
            }
        }
        return result
    }

    // MARK: - Names and data (pkcore's tables)

    static func name(_ dex: Int) -> String {
        pk_nds_species_name(UInt32(dex)).map { String(cString: $0) } ?? "n°\(dex)"
    }

    static func base(_ dex: Int) -> PKNDSBase? {
        var base = PKNDSBase()
        return pk_nds_base_stats(UInt32(dex), &base) ? base : nil
    }

    static func typeName(_ type: UInt8) -> String {
        pk_nds_type_name(UInt32(type)).map { String(cString: $0) } ?? "?"
    }

    static func sprite(_ dex: Int, shiny: Bool = false, animated: Bool = false) -> URL {
        let base = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/"
        let path = (animated ? "animated/" : "") + (shiny ? "shiny/" : "") + "\(dex)" + (animated ? ".gif" : ".png")
        return URL(string: base + path)!
    }

    // MARK: - Cloud

    /// The page reads this: {"games": [...], "dex": {"25": {"g": [[game index, count]], "s": 1}}} (games' boxes only;
    /// it reads the bank itself).
    private func cloudJSON() -> String {
        let names = Array(Set(records.values.flatMap { $0.games.keys })).sorted()
        var dex: [String: Any] = [:]
        for (number, record) in records where !record.games.isEmpty {
            var item: [String: Any] = ["g": record.games.map { [names.firstIndex(of: $0.key) ?? 0, $0.value] }
                .sorted { ($0[0]) < ($1[0]) }]
            if record.gameShiny { item["s"] = 1 }
            dex[String(number)] = item
        }
        let object: [String: Any] = ["games": names, "dex": dex]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func upload(account: AccountStore) async {
        guard let db = account.database, let uid = account.user?.uid else { return }
        let json = cloudJSON()
        let key = "pokedexUploaded.\(uid)"
        guard UserDefaults.standard.string(forKey: key) != json else { return }
        do {
            try await db.set("users/\(uid)/meta/pokedex", fields: ["json": .string(json), "updatedAt": .timestamp(Date())])
            UserDefaults.standard.set(json, forKey: key)
        } catch {
            // Next time.
        }
    }
}
