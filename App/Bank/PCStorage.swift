import Foundation

/// A Pokémon in a PC box, ready to list.
struct BoxedMon: Identifiable {
    let box: Int
    let slot: Int
    /// What the bank keeps: 80 bytes on GBA, structure + names on Game Boy.
    let raw: Data
    let species: Int
    let speciesName: String
    let nickname: String
    let trainer: String
    let isShiny: Bool
    let isEgg: Bool

    var id: Int { box * 64 + slot }

    var displayName: String {
        if isEgg { return "Œuf" }
        if nickname.isEmpty || nickname.caseInsensitiveCompare(speciesName) == .orderedSame {
            return speciesName
        }
        return "\(nickname) (\(speciesName))"
    }
}

/// The PC boxes of one save file, whatever the generation.
protocol PCStorage: AnyObject {
    /// 1, 2 or 3. The bank only moves Pokémon between games of the same generation.
    var generation: Int { get }
    var gameFamily: String { get }
    var summaryLine: String { get }
    var boxCount: Int { get }
    /// Something worth knowing about this save, shown under the boxes.
    var footnote: String? { get }
    func boxName(_ box: Int) -> String
    func listMons(inBox box: Int) -> [BoxedMon]
    /// Puts a Pokémon (bank data) in the first free place. Returns where.
    func deposit(_ raw: Data) throws -> (box: Int, slot: Int)
    func remove(_ mon: BoxedMon) throws
    func write() throws
    func details(of mon: BoxedMon) -> MonDetails?
}

/// A Red/Blue/Yellow or Gold/Silver/Crystal save file. Swift face of `PKGBSave`.
final class GBSaveFile: PCStorage {
    let url: URL
    private let handle: OpaquePointer
    private let sourceGame: String
    private var backedUp = false

    init(url: URL, sourceGame: String) throws {
        self.url = url
        self.sourceGame = sourceGame
        let data = try Data(contentsOf: url)
        var code: Int32 = 0
        let opened: OpaquePointer? = data.withUnsafeBytes { raw in
            pk_gb_save_open(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &code)
        }
        guard let opened = opened else {
            throw GBSaveError(code: code)
        }
        handle = opened
    }

    deinit {
        pk_gb_save_free(handle)
    }

    var generation: Int { Int(pk_gb_save_generation(handle)) }

    var gameFamily: String {
        switch Int(pk_gb_save_game(handle)) {
        case Int(PK_GB_GEN1): return "Rouge / Bleu / Jaune"
        case Int(PK_GB_GS): return "Or / Argent"
        default: return "Cristal"
        }
    }

    var trainerName: String {
        var buffer = [CChar](repeating: 0, count: 48)
        pk_gb_save_trainer_name(handle, &buffer, buffer.count)
        return String(cString: buffer)
    }

    var summaryLine: String {
        "Dresseur \(trainerName) · ID \(String(format: "%05d", Int(pk_gb_save_trainer_id(handle))))"
    }

    var boxCount: Int { Int(pk_gb_box_count(handle)) }

    var currentBox: Int { Int(pk_gb_current_box(handle)) }

    var footnote: String? {
        let unusable = (0..<boxCount).filter { !pk_gb_box_usable(handle, Int32($0)) }
        var lines = ["Boîte sélectionnée dans le jeu : \(boxName(currentBox)). Les Pokémon retirés y vont en priorité."]
        if !unusable.isEmpty {
            lines.append("Les autres boîtes ne sont prêtes qu'après un premier changement de boîte dans le jeu : seule la boîte en cours est utilisable pour l'instant.")
        }
        return lines.joined(separator: " ")
    }

    func boxName(_ box: Int) -> String {
        var buffer = [CChar](repeating: 0, count: 48)
        pk_gb_box_name(handle, Int32(box), &buffer, buffer.count)
        let name = String(cString: buffer)
        return name.isEmpty ? "Boîte \(box + 1)" : name
    }

    private var blobSize: Int { Int(pk_gb_blob_size(handle)) }

    func listMons(inBox box: Int) -> [BoxedMon] {
        let count = Int(pk_gb_box_size(handle, Int32(box)))
        var result: [BoxedMon] = []
        var blob = [UInt8](repeating: 0, count: blobSize)
        for index in 0..<count {
            guard pk_gb_box_mon(handle, Int32(box), Int32(index), &blob) else { continue }
            var mon = PKGBMon()
            guard pk_gb_blob_decode(Int32(generation), blob, blob.count, &mon) else { continue }
            let summary = MonSummary(gb: mon)
            result.append(BoxedMon(box: box, slot: index, raw: Data(blob), species: summary.species,
                                   speciesName: MonDetails.gbSpeciesName(summary.species),
                                   nickname: summary.nickname, trainer: summary.trainerName,
                                   isShiny: summary.isShiny, isEgg: summary.isEgg))
        }
        return result
    }

    func deposit(_ raw: Data) throws -> (box: Int, slot: Int) {
        var box: Int32 = 0
        guard pk_gb_first_free(handle, &box) else {
            throw GBSaveError(code: Int32(PK_ERR_OCCUPIED))
        }
        let code: Int32 = raw.withUnsafeBytes { bytes in
            pk_gb_box_append(handle, box, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        guard code == 0 else {
            throw GBSaveError(code: code)
        }
        return (Int(box), Int(pk_gb_box_size(handle, box)) - 1)
    }

    func remove(_ mon: BoxedMon) throws {
        let code = pk_gb_box_remove(handle, Int32(mon.box), Int32(mon.slot))
        guard code == 0 else {
            throw GBSaveError(code: code)
        }
    }

    func write() throws {
        if !backedUp {
            try SaveBackup.backUp(url)
            backedUp = true
        }
        let size = pk_gb_save_size(handle)
        var output = [UInt8](repeating: 0, count: size)
        guard size > 0, pk_gb_save_write(handle, &output, size) == size else {
            throw GBSaveError(code: Int32(PK_ERR_SIZE))
        }
        try Data(output).write(to: url, options: .atomic)
    }

    func details(of mon: BoxedMon) -> MonDetails? {
        MonDetails.makeGB(generation: generation, raw: mon.raw, party: false, sourceGame: sourceGame)
    }
}

struct GBSaveError: LocalizedError {
    let code: Int32

    var errorDescription: String? {
        switch Int(code) {
        case Int(PK_ERR_SIZE): return "Ce fichier n'est pas une sauvegarde Pokémon Game Boy (taille inattendue)."
        case Int(PK_ERR_NO_SLOT): return "Ce fichier n'a pas le format d'une sauvegarde Pokémon Rouge, Bleu, Jaune, Or, Argent ou Cristal (version occidentale), ou la partie n'a pas encore été sauvegardée. Par prudence, la banque n'y touche pas."
        case Int(PK_ERR_RANGE): return "Cette boîte n'est pas utilisable."
        case Int(PK_ERR_INVALID_MON): return "Ce Pokémon est illisible et ne peut pas être transféré."
        case Int(PK_ERR_OCCUPIED): return "Plus de place dans les boîtes du PC."
        default: return "Erreur inconnue (\(code))."
        }
    }
}
