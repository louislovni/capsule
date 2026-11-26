import Foundation

/// MÉTÉO DS: a GBA game's rain, storms, snow and sandstorms drawn by the core with Pokémon HeartGold / SoulSilver's own
/// sprites, read from the player's cart in the library (nothing bundled; without one, the game keeps its weather).
enum DSWeather {
    static let key = "dsWeather"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// The first HeartGold or SoulSilver cart (any language) in the library: its header's code IPK? / IPG?.
    static func cartURL() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: Storage.roms, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension.lowercased() == "nds" {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let header = try? handle.read(upToCount: 0x10), header.count == 0x10 else { continue }
            let code = [UInt8](header[0x0C..<0x10])
            if code[0] == UInt8(ascii: "I"), code[1] == UInt8(ascii: "P"),
               [UInt8(ascii: "K"), UInt8(ascii: "G")].contains(code[2]) {
                return url
            }
        }
        return nil
    }
}

/// SAISONS: Black / White's seasons on a GBA game's field outdoors: the map's greens in the season's colours and, on fine
/// days, petals in spring, falling leaves in autumn, a little snow in winter (drawn by the core).
enum Seasons: Int, CaseIterable, Identifiable {
    case off = 0
    case blackWhite = 1
    case calendar = 2

    static let key = "seasons"

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Désactivées"
        case .blackWhite: return "Comme Noir et Blanc"
        case .calendar: return "Calendrier"
        }
    }

    /// Black / White change season every month; the calendar's follow the real ones.
    var detail: String {
        switch self {
        case .off: return "Pas de saisons"
        case .blackWhite: return "Une nouvelle saison chaque mois"
        case .calendar: return "Les vraies saisons"
        }
    }

    static var current: Seasons {
        Seasons(rawValue: UserDefaults.standard.object(forKey: key) as? Int ?? 1) ?? .blackWhite
    }
}
