import Foundation

/// BATTLE SPRITES: a GBA battle's Pokémon drawn with Pokémon Black / White (2)'s animated pictures, read by the core from
/// the player's own DS cart in the library (Emerald, FireRed, LeafGreen). Nothing is bundled: without such a cart, nothing changes.
enum BattleSprites {
    static let key = "battleSprites"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// The first Black, White, Black 2 or White 2 cart (any language) in the library: its header's code IRB? / IRA? /
    /// IRE? / IRD?.
    static func cartURL() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: Storage.roms, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension.lowercased() == "nds" {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let header = try? handle.read(upToCount: 0x10), header.count == 0x10 else { continue }
            let code = [UInt8](header[0x0C..<0x10])
            if code[0] == UInt8(ascii: "I"), code[1] == UInt8(ascii: "R"),
               [UInt8(ascii: "B"), UInt8(ascii: "A"), UInt8(ascii: "E"), UInt8(ascii: "D")].contains(code[2]) {
                return url
            }
        }
        return nil
    }
}
