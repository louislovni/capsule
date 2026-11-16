import Foundation

/// The tables of one ROM that Capsule reads: names of species, moves, abilities,
/// items and places, base stats and Pokédex numbers. Located by content, so it
/// works whatever the language. Loading scans the whole ROM: do it off the main thread.
final class RomData {
    let url: URL
    private let data: Data
    private let speciesNames: Int
    private let moveNames: Int
    private let abilityNames: Int
    private let items: Int
    private let baseStatsTable: Int
    private let nationalDexTable: Int
    private let locations: Int
    private let locationKind: Int32
    private let locationCount: UInt32

    private static var cache: [URL: RomData] = [:]
    private static let cacheLock = NSLock()

    /// Loads (or returns the already loaded) tables of a ROM file.
    static func load(_ url: URL) -> RomData? {
        cacheLock.lock()
        if let cached = cache[url] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        guard let loaded = RomData(url: url) else { return nil }
        cacheLock.lock()
        cache[url] = loaded
        cacheLock.unlock()
        return loaded
    }

    /// A ROM to read names from when no particular game is at hand: the one the
    /// Pokémon came from if it is still in the library, otherwise any of them.
    static func anyROM(preferring name: String?) -> RomData? {
        let manager = FileManager.default
        if let name = name {
            let preferred = Storage.roms.appendingPathComponent(name + ".gba")
            if manager.fileExists(atPath: preferred.path), let rom = load(preferred) {
                return rom
            }
        }
        let files = (try? manager.contentsOfDirectory(at: Storage.roms, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "gba" {
            if let rom = load(file) {
                return rom
            }
        }
        return nil
    }

    private init?(url: URL) {
        guard let loaded = try? Data(contentsOf: url, options: .alwaysMapped), loaded.count > 0xC0 else {
            return nil
        }
        self.url = url
        data = loaded
        var kind: Int32 = 0
        var count: UInt32 = 0
        var found = (0, 0, 0, 0, 0, 0, 0)
        loaded.withUnsafeBytes { raw in
            let rom = raw.bindMemory(to: UInt8.self).baseAddress
            let size = raw.count
            found = (
                pk_rom_find_species_names(rom, size),
                pk_rom_find_move_names(rom, size),
                pk_rom_find_ability_names(rom, size),
                pk_rom_find_items(rom, size),
                pk_rom_find_base_stats(rom, size),
                pk_rom_find_national_dex(rom, size),
                pk_rom_find_location_names(rom, size, &kind, &count)
            )
        }
        speciesNames = found.0
        moveNames = found.1
        abilityNames = found.2
        items = found.3
        baseStatsTable = found.4
        nationalDexTable = found.5
        locations = found.6
        locationKind = kind
        locationCount = count
    }

    private func withROM<T>(_ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
        data.withUnsafeBytes { raw in
            body(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
    }

    private func tableName(_ table: Int, stride: Int, index: Int) -> String? {
        guard table >= 0, index >= 0 else { return nil }
        return withROM { rom, size in
            NameLookup.name(rom: rom, size: size, table: table, stride: stride, index: index)
        }
    }

    func speciesName(_ index: Int) -> String? { tableName(speciesNames, stride: Int(PK_SPECIES_NAME_STRIDE), index: index) }
    func moveName(_ index: Int) -> String? { tableName(moveNames, stride: Int(PK_MOVE_NAME_STRIDE), index: index) }
    func abilityName(_ index: Int) -> String? { tableName(abilityNames, stride: Int(PK_ABILITY_NAME_STRIDE), index: index) }
    func itemName(_ index: Int) -> String? { tableName(items, stride: Int(PK_ITEM_STRIDE), index: index) }

    func baseStats(species: Int) -> PKBaseStats? {
        guard baseStatsTable >= 0, species > 0, species <= 0xFFFF else { return nil }
        var stats = PKBaseStats()
        let ok = withROM { rom, size in
            pk_rom_base_stats(rom, size, baseStatsTable, UInt16(species), &stats)
        }
        return ok ? stats : nil
    }

    func nationalDex(species: Int) -> Int? {
        guard nationalDexTable >= 0, species > 0, species <= 0xFFFF else { return nil }
        let number = withROM { rom, size in
            pk_rom_national_dex(rom, size, nationalDexTable, UInt16(species))
        }
        return number > 0 ? Int(number) : nil
    }

    func locationName(_ location: Int) -> String? {
        guard locations >= 0, location >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 48)
        withROM { rom, size in
            pk_rom_location_name(rom, size, locations, locationKind, locationCount, UInt32(location), &buffer, buffer.count)
        }
        let text = String(cString: buffer)
        return text.isEmpty ? nil : text
    }
}
