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
    /// 1 or 2 for Game Boy Pokémon, 4 or 5 for DS ones; nil for GBA ones (generation 3).
    var generation: Int?

    var effectiveGeneration: Int { generation ?? 3 }

    /// Size of `data` for each generation.
    static func dataSize(generation: Int) -> Int {
        switch generation {
        case 1: return Int(PK_GB1_BLOB)
        case 2: return Int(PK_GB2_BLOB)
        case 4, 5: return NDSSaveFile.monSize
        default: return SaveFile.monSize
        }
    }

    /// Details to show: the saved ones, or worked out now.
    func resolvedDetails() -> MonDetails? {
        if let details = details {
            return details
        }
        if let generation = generation, generation >= 4 {
            return MonDetails.makeNDS(generation: generation, raw: data, sourceGame: sourceGame)
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

enum TradeError: LocalizedError {
    case notInBank, unreadable

    var errorDescription: String? {
        switch self {
        case .notInBank: return "Ce Pokémon n'est plus dans ta banque."
        case .unreadable: return "Le Pokémon reçu est illisible."
        }
    }
}

/// The bank: a JSON file in Documents/Bank. It can be exported and merged back,
/// which is how it travels between devices for now.
final class BankStore: ObservableObject {
    @Published private(set) var entries: [BankEntry] = []
    @Published var lastError: String?

    let fileURL = Storage.bank.appendingPathComponent("banque.json")
    /// Pokémon that left the bank (withdrawn, traded): the cloud's merge keeps them out, so one
    /// another device still holds doesn't come back.
    private(set) var removedIDs: Set<UUID> = []
    private let removedURL = Storage.bank.appendingPathComponent("retires.json")

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
        if let data = try? Data(contentsOf: removedURL), let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            removedIDs = Set(ids)
        }
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
        let removed = try JSONEncoder().encode(removedIDs.map { $0 }.sorted { $0.uuidString < $1.uuidString })
        try removed.write(to: removedURL, options: .atomic)
    }

    // MARK: - Cloud

    struct CloudPayload: Codable {
        var entries: [BankEntry]
        var removed: [UUID]
    }

    /// The bank as the cloud keeps it (the same bytes for the same bank).
    func cloudPayload() throws -> Data {
        let payload = CloudPayload(entries: entries.sorted { $0.id.uuidString < $1.id.uuidString },
                                   removed: removedIDs.sorted { $0.uuidString < $1.uuidString })
        return try Self.makeEncoder().encode(payload)
    }

    /// Another device's bank merged in: every Pokémon either holds, but none that left either.
    func mergeCloud(_ data: Data) throws {
        let cloud = try Self.makeDecoder().decode(CloudPayload.self, from: data)
        let removed = removedIDs.union(cloud.removed)
        var merged = entries.filter { !removed.contains($0.id) }
        let known = Set(merged.map { $0.id })
        merged += cloud.entries.filter {
            !known.contains($0.id) && !removed.contains($0.id)
                && $0.data.count == BankEntry.dataSize(generation: $0.effectiveGeneration)
        }
        guard merged != entries || removed != removedIDs else { return }
        let before = (entries, removedIDs)
        entries = merged
        removedIDs = removed
        do {
            try persist()
        } catch {
            (entries, removedIDs) = before
            throw error
        }
    }

    func add(_ entry: BankEntry) throws {
        entries.append(entry)
        removedIDs.remove(entry.id)
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
        removedIDs.insert(removed.id)
        do {
            try persist()
        } catch {
            entries.insert(removed, at: index)
            removedIDs.remove(removed.id)
            throw error
        }
    }

    /// A trade with another phone: `outgoing` leaves the bank, `incoming` takes its place.
    /// What leaves is first copied to Bank/Echanges (a bank file of one, which the import
    /// takes back), so a trade cut short on the other side never loses a Pokémon.
    /// The received Pokémon evolves as it would in the games (Kadabra, Onix holding a Metal Coat…).
    /// Returns it as kept, with its name before the trade when it evolved.
    func trade(giving outgoing: BankEntry, receiving incoming: BankEntry) throws -> (entry: BankEntry, evolvedFrom: String?) {
        guard let index = entries.firstIndex(where: { $0.id == outgoing.id }) else {
            throw TradeError.notInBank
        }
        guard incoming.data.count == BankEntry.dataSize(generation: incoming.effectiveGeneration) else {
            throw TradeError.unreadable
        }
        var received = TradeEvolution.apply(to: incoming, tradedFor: outgoing)
        let evolvedFrom = received.species != incoming.species ? incoming.displayName : nil
        if entries.contains(where: { $0.id == received.id && $0.id != outgoing.id }) {
            received.id = UUID()
        }
        received.depositedAt = Date()

        let folder = Storage.bank.appendingPathComponent("Echanges", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = folder.appendingPathComponent("envoye-\(stamp)-\(outgoing.id.uuidString.prefix(8)).json")
        try Self.makeEncoder().encode([outgoing]).write(to: backup, options: .atomic)

        let before = (entries, removedIDs)
        entries[index] = received
        removedIDs.insert(outgoing.id)
        removedIDs.remove(received.id)
        do {
            try persist()
        } catch {
            (entries, removedIDs) = before
            throw error
        }
        return (received, evolvedFrom)
    }

    /// Adds the entries of an exported bank file that are not here yet.
    /// Returns how many were added.
    func merge(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let incoming = try Self.makeDecoder().decode([BankEntry].self, from: data)
        let known = Set(entries.map { $0.id })
        // Brought back on purpose (a file kept from a trade, say): no longer counted as gone.
        removedIDs.subtract(incoming.map { $0.id })
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
