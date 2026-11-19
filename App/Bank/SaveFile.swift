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

/// A Generation 3 save file opened for PC box access. Swift face of `PKSave`.
final class SaveFile: PCStorage {
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

    struct Slot {
        let box: Int
        let slot: Int
        let raw: Data
        let summary: MonSummary
    }

    /// Every Pokémon stored in the given box.
    func mons(inBox box: Int) -> [Slot] {
        var result: [Slot] = []
        for slot in 0..<Self.slotsPerBox {
            guard let pointer = pk_save_box_mon(handle, Int32(box), Int32(slot)), !pk_mon_is_empty(pointer) else {
                continue
            }
            var mon = PKMon()
            guard pk_mon_decode(pointer, Self.monSize, &mon) else { continue }
            let raw = Data(bytes: pointer, count: Self.monSize)
            result.append(Slot(box: box, slot: slot, raw: raw, summary: MonSummary(mon)))
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
        // The official games' last species (internal 411), move (354) and item (376): a hack's past them stays out.
        var mon = PKMon()
        let decoded = raw.withUnsafeBytes { bytes in
            pk_mon_decode(bytes.bindMemory(to: UInt8.self).baseAddress, raw.count, &mon)
        }
        if decoded {
            if mon.species > 411 {
                throw GameLacksError(reason: "Ce Pokémon n'existe pas dans ce jeu.")
            }
            if let move = [mon.moves.0, mon.moves.1, mon.moves.2, mon.moves.3].first(where: { $0 > 354 }) {
                throw GameLacksError(reason: "Il connaît une capacité (n° \(move)) qui n'existe pas dans ce jeu.")
            }
            if mon.heldItem > 376 {
                throw GameLacksError(reason: "L'objet qu'il tient n'existe pas dans ce jeu : retire-le dans le jeu d'origine d'abord.")
            }
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

    /// Writes the changes back to disk, keeping a dated copy of the original first.
    func write() throws {
        if !backedUp {
            try SaveBackup.backUp(url)
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

    // MARK: - PCStorage

    /// Names come from the game's ROM, when it could be read.
    var rom: RomData?

    var generation: Int { 3 }
    var boxCount: Int { Self.boxCount }
    var summaryLine: String { "Dresseur \(trainerName) · \(playTime)" }
    var footnote: String? { nil }

    func listMons(inBox box: Int) -> [BoxedMon] {
        mons(inBox: box).map { item in
            let summary = item.summary
            let speciesName = rom?.speciesName(summary.species) ?? "Pokémon n°\(summary.species)"
            return BoxedMon(box: item.box, slot: item.slot, raw: item.raw, species: summary.species,
                            speciesName: speciesName, nickname: summary.nickname, trainer: summary.trainerName,
                            isShiny: summary.isShiny, isEgg: summary.isEgg)
        }
    }

    func remove(_ mon: BoxedMon) throws {
        try remove(box: mon.box, slot: mon.slot)
    }

    func details(of mon: BoxedMon) -> MonDetails? {
        MonDetails.make(raw: mon.raw, rom: rom)
    }
}

/// A dated copy of a save file, made before Capsule first changes it.
enum SaveBackup {
    static func backUp(_ url: URL) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = url.deletingPathExtension().lastPathComponent
        let destination = Storage.backups.appendingPathComponent("\(name)-\(formatter.string(from: Date())).sav")
        try? FileManager.default.createDirectory(at: Storage.backups, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: url, to: destination)
        }
        prune(name)
    }

    /// Keeps the 10 most recent backups of a game.
    private static func prune(_ name: String) {
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

extension SaveFile {
    /// The team: species (the game's own index) and shiny.
    func teamSpecies() -> [(species: Int, shiny: Bool)] {
        var buffer = [UInt8](repeating: 0, count: 6 * Int(PK_PARTY_MON_SIZE))
        let count = Int(pk_save_party(handle, &buffer))
        return (0..<count).compactMap { index in
            var mon = PKMon()
            let start = index * Int(PK_PARTY_MON_SIZE)
            let ok = buffer[start..<start + Int(PK_PARTY_MON_SIZE)].withUnsafeBufferPointer { pk_mon_decode($0.baseAddress, $0.count, &mon) }
            return ok && !mon.isEgg ? (Int(mon.species), mon.isShiny) : nil
        }
    }

    /// The game's own Pokédex: National numbers caught and seen.
    func pokedexFlags() -> (caught: Set<Int>, seen: Set<Int>)? {
        var caught = [UInt8](repeating: 0, count: Int(PK_DEX_FLAG_BYTES))
        var seen = caught
        guard pk_save_pokedex(handle, &caught, &seen) else { return nil }
        func numbers(_ bits: [UInt8]) -> Set<Int> {
            var out = Set<Int>()
            for index in 0..<(bits.count * 8) where bits[index / 8] & (1 << (index % 8)) != 0 {
                out.insert(index + 1)
            }
            return out
        }
        return (numbers(caught), numbers(seen))
    }
}
