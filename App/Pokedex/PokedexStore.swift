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
        /// Game name → how many in its boxes and team.
        var games: [String: Int] = [:]
        /// Games where it is in the team.
        var team: Set<String> = []
        var gameShiny = false
        /// Games whose own Pokédex says caught / seen.
        var dexCaught: Set<String> = []
        var dexSeen: Set<String> = []

        var shiny: Bool { bankShiny || gameShiny }
        /// Caught: in the bank, in a game, or caught once according to a game's Pokédex.
        var owned: Bool { bank > 0 || !games.isEmpty || !dexCaught.isEmpty }
    }

    @Published private(set) var records: [Int: Record] = [:]
    @Published private(set) var scanning = false

    /// What each game's boxes held, by save file date (scanning a GBA game reads its ROM).
    private struct GameScan: Codable, Equatable {
        var saveDate: Date
        var mons: [[Int]] // [dex, shiny 0/1, in the team 0/1]
        var caught: [Int]
        var seen: [Int]
    }
    private var scans: [String: GameScan] = [:]
    private let cacheURL = Storage.bank.appendingPathComponent("pokedex-jeux.json")

    init() {
        if let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode([String: GameScan].self, from: data) {
            scans = saved
        }
    }

    var caught: Int { records.values.filter(\.owned).count }
    var seenOnly: Int { records.values.filter { !$0.owned }.count }

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
            newScans[game.name] = await Task.detached(priority: .utility) { Self.scan(game, date: date) }.value
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
            for mon in scan.mons where mon.count == 3 && (1...Self.maxDex).contains(mon[0]) {
                built[mon[0], default: Record()].games[name, default: 0] += 1
                if mon[1] == 1 { built[mon[0]]?.gameShiny = true }
                if mon[2] == 1 { built[mon[0]]?.team.insert(name) }
            }
            for dex in scan.caught where (1...Self.maxDex).contains(dex) {
                built[dex, default: Record()].dexCaught.insert(name)
            }
            for dex in scan.seen where (1...Self.maxDex).contains(dex) {
                built[dex, default: Record()].dexSeen.insert(name)
            }
        }
        if built != records {
            records = built
        }
    }

    /// A game's boxes, team and own Pokédex.
    nonisolated private static func scan(_ game: Game, date: Date) -> GameScan {
        var result = GameScan(saveDate: date, mons: [], caught: [], seen: [])
        var mons: [(species: Int, shiny: Bool, team: Bool)] = []
        var flags: (caught: Set<Int>, seen: Set<Int>)?
        var storage: PCStorage?
        var rom: RomData?
        if game.isDS, let save = try? NDSSaveFile(url: game.saveURL, sourceGame: game.name) {
            storage = save
            mons += save.teamSpecies().map { ($0.species, $0.shiny, true) }
            flags = save.pokedexFlags()
        } else if game.romURL.pathExtension.lowercased() == "gba", let save = try? SaveFile(url: game.saveURL) {
            rom = RomData.load(game.romURL)
            save.rom = rom
            storage = save
            mons += save.teamSpecies().map { ($0.species, $0.shiny, true) }
            flags = save.pokedexFlags()
        } else if !game.isDS, let save = try? GBSaveFile(url: game.saveURL, sourceGame: game.name) {
            storage = save
            mons += save.teamSpecies().map { ($0.species, $0.shiny, true) }
            flags = save.pokedexFlags()
        }
        guard let storage = storage else { return result }
        for box in 0..<storage.boxCount {
            for mon in storage.listMons(inBox: box) where !mon.isEgg {
                mons.append((mon.species, mon.isShiny, false))
            }
        }
        for mon in mons {
            var dex = mon.species
            if storage.generation == 3 {
                guard let number = rom?.nationalDex(species: mon.species) ?? (mon.species <= 251 ? mon.species : nil) else { continue }
                dex = number
            }
            result.mons.append([dex, mon.shiny ? 1 : 0, mon.team ? 1 : 0])
        }
        // A save whose flags make no sense (a hack's layout, say) is left out.
        if let flags = flags, flags.caught.isSubset(of: flags.seen), !flags.seen.isEmpty {
            result.caught = flags.caught.sorted()
            result.seen = flags.seen.subtracting(flags.caught).sorted()
        }
        return result
    }

    // MARK: - Names and data (pkcore's tables)

    /// "Pokemon - Version Emeraude (FR)" → "Emeraude".
    static func gameTitle(_ name: String) -> String {
        var text = name.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^[Pp]ok[eé]mon\s*[-:–]?\s*([Vv]ersion\s+)?"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? name : text
    }

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

    /// The page reads this (it reads the bank itself): {"games": [...], "dex": {"25": {"g": [[game, count]]
    /// (boxes and team), "t": [games with it in the team], "s": 1 (shiny), "d": [games whose Pokédex has it
    /// caught], "v": [... seen only]}}}, games as indexes into "games".
    private func cloudJSON() -> String {
        let names = Array(Set(records.values.flatMap { Array($0.games.keys) + Array($0.dexCaught) + Array($0.dexSeen) })).sorted()
        var dex: [String: Any] = [:]
        let index = { (name: String) in names.firstIndex(of: name) ?? 0 }
        for (number, record) in records {
            var item: [String: Any] = [:]
            if !record.games.isEmpty {
                item["g"] = record.games.map { [index($0.key), $0.value] }.sorted { $0[0] < $1[0] }
            }
            if !record.team.isEmpty { item["t"] = record.team.map(index).sorted() }
            if record.gameShiny { item["s"] = 1 }
            if !record.dexCaught.isEmpty { item["d"] = record.dexCaught.map(index).sorted() }
            if !record.dexSeen.isEmpty { item["v"] = record.dexSeen.map(index).sorted() }
            if !item.isEmpty { dex[String(number)] = item }
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
