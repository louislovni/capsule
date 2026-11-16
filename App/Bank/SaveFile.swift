import Foundation

/// Why a save file could not be used.
struct SaveFileError: LocalizedError {
    let code: Int32

    var errorDescription: String? {
        switch code {
        case 1: return "Ce fichier n'est pas une sauvegarde de Pokémon GBA (taille inattendue)."
        case 2: return "Aucune partie enregistrée dans ce fichier. Lance le jeu et sauvegarde une fois depuis son menu."
        case 3: return "Le PC de cette sauvegarde n'a pas le format attendu (jeu modifié ou fichier abîmé). Par prudence, la banque n'y touche pas."
        case 4: return "Mémoire insuffisante."
        case 5: return "Emplacement de boîte invalide."
        case 6: return "Ce Pokémon est illisible et ne peut pas être transféré."
        case 7: return "Cet emplacement est déjà occupé."
        default: return "Erreur inconnue (\(code))."
        }
    }
}

/// A Pokémon sitting in a PC box of a save file.
struct BoxedMon: Identifiable {
    let box: Int
    let slot: Int
    let raw: Data
    let summary: MonSummary

    var id: Int { box * 30 + slot }
}

/// A Generation 3 save file opened for PC box access. Swift face of `PKSave`.
final class SaveFile {
    static let boxCount = 14
    static let slotsPerBox = 30
    static let monSize = 80

    let url: URL
    private let handle: OpaquePointer
    private var backedUp = false

    init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url)
        var code: Int32 = 0
        let opened: OpaquePointer? = data.withUnsafeBytes { raw in
            pk_save_open(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &code)
        }
        guard let opened = opened else {
            throw SaveFileError(code: code)
        }
        handle = opened
    }

    deinit {
        pk_save_free(handle)
    }

    var trainerName: String {
        var buffer = [CChar](repeating: 0, count: 48)
        pk_save_trainer_name(handle, &buffer, buffer.count)
        return String(cString: buffer)
    }

    var gameFamily: String {
        switch pk_save_game(handle) {
        case 1: return "Rubis / Saphir"
        case 2: return "Rouge Feu / Vert Feuille"
        case 3: return "Émeraude"
        default: return "Jeu inconnu"
        }
    }

    var playTime: String {
        let packed = pk_save_play_time(handle)
        return "\(packed >> 16) h \(packed & 0xFFFF) min"
    }

    func boxName(_ box: Int) -> String {
        var buffer = [CChar](repeating: 0, count: 48)
        pk_save_box_name(handle, Int32(box), &buffer, buffer.count)
        let name = String(cString: buffer)
        return name.isEmpty ? "Boîte \(box + 1)" : name
    }

    /// Every Pokémon stored in the given box.
    func mons(inBox box: Int) -> [BoxedMon] {
        var result: [BoxedMon] = []
        for slot in 0..<Self.slotsPerBox {
            guard let pointer = pk_save_box_mon(handle, Int32(box), Int32(slot)), !pk_mon_is_empty(pointer) else {
                continue
            }
            var mon = PKMon()
            guard pk_mon_decode(pointer, Self.monSize, &mon) else { continue }
            let raw = Data(bytes: pointer, count: Self.monSize)
            result.append(BoxedMon(box: box, slot: slot, raw: raw, summary: MonSummary(mon)))
        }
        return result
    }

    var hasFreeSlot: Bool {
        pk_save_first_empty(handle, nil, nil)
    }

    /// Puts a Pokémon in the first free PC slot. Returns where it went.
    func deposit(_ raw: Data) throws -> (box: Int, slot: Int) {
        guard raw.count == Self.monSize else {
            throw SaveFileError(code: 6)
        }
        var box: Int32 = 0
        var slot: Int32 = 0
        guard pk_save_first_empty(handle, &box, &slot) else {
            throw SaveFileError(code: 7)
        }
        let code: Int32 = raw.withUnsafeBytes { bytes in
            pk_save_put_box_mon(handle, box, slot, bytes.bindMemory(to: UInt8.self).baseAddress)
        }
        guard code == 0 else {
            throw SaveFileError(code: code)
        }
        return (Int(box), Int(slot))
    }

    func remove(box: Int, slot: Int) throws {
        let code = pk_save_clear_box_mon(handle, Int32(box), Int32(slot))
        guard code == 0 else {
            throw SaveFileError(code: code)
        }
    }

    /// Writes the changes back to disk. The first write of a session keeps a dated
    /// copy of the original file in Backups.
    func write() throws {
        if !backedUp {
            try backUp()
            backedUp = true
        }
        let size = pk_save_size(handle)
        var output = [UInt8](repeating: 0, count: size)
        let written = pk_save_write(handle, &output, size)
        guard written == size, size > 0 else {
            throw SaveFileError(code: 1)
        }
        try Data(output).write(to: url, options: .atomic)
    }

    private func backUp() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = url.deletingPathExtension().lastPathComponent
        let destination = Storage.backups.appendingPathComponent("\(name)-\(formatter.string(from: Date())).sav")
        try? FileManager.default.createDirectory(at: Storage.backups, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: url, to: destination)
        }
        pruneBackups(for: name)
    }

    /// Keeps the 10 most recent backups of a game.
    private func pruneBackups(for name: String) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: Storage.backups, includingPropertiesForKeys: nil) else {
            return
        }
        let mine = files
            .filter { $0.lastPathComponent.hasPrefix(name + "-") && $0.pathExtension == "sav" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in mine.dropFirst(10) {
            try? manager.removeItem(at: old)
        }
    }
}

/// Species names read from a ROM file, in the ROM's own language.
final class RomNames {
    private let data: Data
    private let speciesTable: Int

    init?(url: URL) {
        guard let loaded = try? Data(contentsOf: url, options: .alwaysMapped) else {
            return nil
        }
        data = loaded
        speciesTable = loaded.withUnsafeBytes { raw in
            pk_rom_find_species_names(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
    }

    func species(_ index: Int) -> String {
        let found: String? = data.withUnsafeBytes { raw in
            NameLookup.name(rom: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count,
                            table: speciesTable, stride: NameLookup.speciesStride, index: index)
        }
        return found ?? "Pokémon n°\(index)"
    }
}
