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

/// POKÉMON QUI SUIT: the party's lead walking behind the player in a GBA game, as HeartGold / SoulSilver's following
/// Pokémon, drawn from the player's own cart (the same one MÉTÉO DS reads).
/// SON EN ACCÉLÉRÉ: in fast-forward, a Gen 3 game's music and sounds (moves, menus, cries) heard at their normal speed,
/// from a copy of the game the core keeps playing at 1x; off = silent fast-forward, as before.
enum FFSound {
    static let key = "ffSound"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

/// MÉTÉO DYNAMIQUE: on the game's fine days outdoors, rain, storms or (in a season's winter) snow come and go by
/// themselves, each area its own sky for each 12 minutes; drawn with HeartGold / SoulSilver's weather from the player's cart.
enum DynamicWeather {
    static let key = "dynamicWeather"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

enum Follower {
    static let key = "follower"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

/// SAISONS: seasons on a GBA game's field outdoors: the map's greens in the season's colours and, on fine days, petals in
/// spring, falling leaves in autumn, a little snow in winter (drawn by the core). The raw values are the core's
/// (retro_pd_ambience), the cases in the menu's order.
enum Seasons: Int, CaseIterable, Identifiable {
    case off = 0
    case blackWhite = 1
    case calendar = 2
    case playTime = 7
    case byArea = 8
    case spring = 3
    case summer = 4
    case autumn = 5
    case winter = 6

    static let key = "seasons"

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Désactivées"
        case .blackWhite: return "Comme Noir et Blanc (chaque mois)"
        case .calendar: return "Calendrier (vraies saisons)"
        case .playTime: return "Toutes les 20 min de jeu"
        case .byArea: return "Selon la zone"
        case .spring: return "Printemps"
        case .summer: return "Été"
        case .autumn: return "Automne"
        case .winter: return "Hiver"
        }
    }

    static var current: Seasons {
        Seasons(rawValue: UserDefaults.standard.object(forKey: key) as? Int ?? 1) ?? .blackWhite
    }
}
