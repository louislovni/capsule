import Foundation

/// Reads a fixed-size C string field (imported by Swift as a tuple of bytes).
func stringFromCField<T>(_ field: T) -> String {
    withUnsafeBytes(of: field) { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}

/// Looks names up in the tables found inside a ROM by `pk_rom_find_*`.
enum NameLookup {
    static let speciesStride = 11
    static let moveStride = 13

    static func name(rom: UnsafePointer<UInt8>?, size: Int, table: Int, stride: Int, index: Int) -> String? {
        guard let rom = rom, table >= 0, index >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 48)
        pk_rom_table_name(rom, size, table, stride, UInt32(index), &buffer, buffer.count)
        let text = String(cString: buffer)
        return text.isEmpty ? nil : text
    }
}

/// A decoded Pokémon, in Swift terms.
struct MonSummary: Equatable {
    let species: Int
    let nickname: String
    let trainerName: String
    let isShiny: Bool
    let isEgg: Bool
    let moves: [Int]
    let level: Int
    let hp: Int
    let maxHp: Int
    let status: UInt32

    init(_ mon: PKMon) {
        species = Int(mon.species)
        nickname = stringFromCField(mon.nickname)
        trainerName = stringFromCField(mon.otName)
        isShiny = mon.isShiny
        isEgg = mon.isEgg
        moves = [Int(mon.moves.0), Int(mon.moves.1), Int(mon.moves.2), Int(mon.moves.3)].filter { $0 != 0 }
        level = Int(mon.level)
        hp = Int(mon.hp)
        maxHp = Int(mon.maxHp)
        status = mon.status
    }

    /// Short label for the status condition, or nil when healthy.
    var statusLabel: String? {
        if maxHp > 0 && hp == 0 { return "K.O." }
        if status & 0x07 != 0 { return "SOM" }
        if status & 0x08 != 0 || status & 0x80 != 0 { return "PSN" }
        if status & 0x10 != 0 { return "BRU" }
        if status & 0x20 != 0 { return "GEL" }
        if status & 0x40 != 0 { return "PAR" }
        return nil
    }
}
