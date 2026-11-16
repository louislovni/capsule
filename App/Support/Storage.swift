import Foundation

/// Where everything lives. The Documents folder is visible in the Files app
/// ("Sur mon iPhone > Capsule"), so ROMs and saves can be dropped in from there.
enum Storage {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let roms = documents.appendingPathComponent("ROMs", isDirectory: true)
    static let saves = documents.appendingPathComponent("Saves", isDirectory: true)
    static let states = documents.appendingPathComponent("States", isDirectory: true)
    static let bank = documents.appendingPathComponent("Bank", isDirectory: true)
    static let backups = documents.appendingPathComponent("Backups", isDirectory: true)

    static func prepare() {
        for directory in [roms, saves, states, bank, backups] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func modificationDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}

/// One ROM in the library, with the files that go with it.
struct Game: Identifiable, Hashable {
    let romURL: URL

    var id: URL { romURL }
    var name: String { romURL.deletingPathExtension().lastPathComponent }
    var saveURL: URL { Storage.saves.appendingPathComponent(name + ".sav") }

    func stateURL(slot: Int) -> URL {
        Storage.states.appendingPathComponent("\(name).ss\(slot)")
    }

    var hasSave: Bool { FileManager.default.fileExists(atPath: saveURL.path) }

    static let romExtensions: Set<String> = ["gba", "gb", "gbc"]

    var platformLabel: String {
        switch romURL.pathExtension.lowercased() {
        case "gb": return "Game Boy"
        case "gbc": return "Game Boy Color"
        default: return "GBA"
        }
    }

    /// The Pokémon bank and the companion only know the GBA games.
    var supportsPokemonTools: Bool { romURL.pathExtension.lowercased() == "gba" }

    /// Remembers when Pokémon were last moved between this game's save and the bank,
    /// so that loading an older save state can be flagged.
    private var transferKey: String { "lastBankTransfer." + name }

    var lastBankTransfer: Date? {
        UserDefaults.standard.object(forKey: transferKey) as? Date
    }

    func markBankTransfer() {
        UserDefaults.standard.set(Date(), forKey: transferKey)
    }
}
