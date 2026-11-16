import Combine
import Foundation

/// One Pokémon held by the bank: the raw 80-byte structure, plus what is needed
/// to show it without a game at hand.
struct BankEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var data: Data
    var species: Int
    var speciesName: String
    var nickname: String
    var trainerName: String
    var isShiny: Bool
    var isEgg: Bool
    var sourceGame: String
    var depositedAt: Date
    /// Details worked out with the ROM of the game it came from, when deposited.
    /// Missing for Pokémon deposited by the first version of the app.
    var details: MonDetails?
    /// 1 or 2 for Game Boy Pokémon; nil for GBA ones (generation 3).
    var generation: Int?

    var effectiveGeneration: Int { generation ?? 3 }

    /// Size of `data` for each generation.
    static func dataSize(generation: Int) -> Int {
        switch generation {
        case 1: return Int(PK_GB1_BLOB)
        case 2: return Int(PK_GB2_BLOB)
        default: return SaveFile.monSize
        }
    }

    /// Details to show: the saved ones, or worked out now.
    func resolvedDetails() -> MonDetails? {
        if let details = details {
            return details
        }
        if let generation = generation {
            return MonDetails.makeGB(generation: generation, raw: data, party: false, sourceGame: sourceGame)
        }
        return MonDetails.make(raw: data, rom: RomData.anyROM(preferring: sourceGame))
    }

    var displayName: String {
        if isEgg { return "Œuf" }
        if nickname.isEmpty || nickname.caseInsensitiveCompare(speciesName) == .orderedSame {
            return speciesName
        }
        return "\(nickname) (\(speciesName))"
    }
}

/// The bank: a JSON file in Documents/Bank. It can be exported and merged back,
/// which is how it travels between devices for now.
final class BankStore: ObservableObject {
    @Published private(set) var entries: [BankEntry] = []
    @Published var lastError: String?

    let fileURL = Storage.bank.appendingPathComponent("banque.json")

    init() {
        load()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return
        }
        do {
            entries = try Self.makeDecoder().decode([BankEntry].self, from: data)
        } catch {
            // Never overwrite a file we could not read: keep it aside for recovery.
            let aside = Storage.bank.appendingPathComponent("banque-illisible-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            entries = []
            lastError = "Le fichier de la banque était illisible. Il a été mis de côté sous le nom \(aside.lastPathComponent)."
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: Storage.bank, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    func add(_ entry: BankEntry) throws {
        entries.append(entry)
        do {
            try persist()
        } catch {
            entries.removeAll { $0.id == entry.id }
            throw error
        }
    }

    func remove(_ entry: BankEntry) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let removed = entries.remove(at: index)
        do {
            try persist()
        } catch {
            entries.insert(removed, at: index)
            throw error
        }
    }

    /// Adds the entries of an exported bank file that are not here yet.
    /// Returns how many were added.
    func merge(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let incoming = try Self.makeDecoder().decode([BankEntry].self, from: data)
        let known = Set(entries.map { $0.id })
        let fresh = incoming.filter {
            !known.contains($0.id) && $0.data.count == BankEntry.dataSize(generation: $0.effectiveGeneration)
        }
        guard !fresh.isEmpty else { return 0 }
        let before = entries
        entries.append(contentsOf: fresh)
        do {
            try persist()
        } catch {
            entries = before
            throw error
        }
        return fresh.count
    }
}
