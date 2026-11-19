import Foundation

/// A Diamond/Pearl/Platinum, HeartGold/SoulSilver, Black/White or Black 2/White 2
/// save file. Swift face of `PKNDSSave`.
final class NDSSaveFile: PCStorage {
    static let monSize = Int(PK_NDS_MON_SIZE)
    static let slotsPerBox = 30

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
            pk_nds_save_open(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &code)
        }
        guard let opened = opened else {
            throw NDSSaveError(code: code)
        }
        handle = opened
    }

    deinit {
        pk_nds_save_free(handle)
    }

    var generation: Int { Int(pk_nds_save_generation(handle)) }

    /// An hg-engine hack's save (Chaos Purple): 30 boxes, its own Pokémon past ARCEUS.
    var isHgEngine: Bool { pk_nds_save_hg_engine(handle) }

    var gameFamily: String {
        switch Int(pk_nds_save_game(handle)) {
        case Int(PK_NDS_DP): return "Diamant / Perle"
        case Int(PK_NDS_PT): return "Platine"
        case Int(PK_NDS_HGSS):
            return isHgEngine ? "hack HeartGold (hg-engine)" : "Or HeartGold / Argent SoulSilver"
        case Int(PK_NDS_BW): return "Noire / Blanche"
        default: return "Noire 2 / Blanche 2"
        }
    }

    var trainerName: String {
        var buffer = [CChar](repeating: 0, count: 48)
        pk_nds_save_trainer_name(handle, &buffer, buffer.count)
        return String(cString: buffer)
    }

    var summaryLine: String {
        "Dresseur \(trainerName) · ID \(String(format: "%05d", Int(pk_nds_save_trainer_id(handle))))"
    }

    var boxCount: Int { Int(pk_nds_box_count(handle)) }

    var footnote: String? {
        var lines = ["Les Pokémon retirés vont dans la première place libre, en commençant par la boîte sélectionnée dans le jeu."]
        if generation == 5 && boxCount < 24 {
            lines.append("\(boxCount) boîtes sont débloquées pour l'instant : le jeu en ajoute quand elles se remplissent.")
        }
        if generation == 4 {
            lines.append("Seuls les Pokémon de la 4e génération (jusqu'au n° 493) et leurs objets et capacités connus du jeu peuvent y entrer.")
        }
        return lines.joined(separator: " ")
    }

    func boxName(_ box: Int) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        pk_nds_box_name(handle, Int32(box), &buffer, buffer.count)
        let name = String(cString: buffer)
        return name.isEmpty ? "Boîte \(box + 1)" : name
    }

    func listMons(inBox box: Int) -> [BoxedMon] {
        var result: [BoxedMon] = []
        var raw = [UInt8](repeating: 0, count: Self.monSize)
        for slot in 0..<Self.slotsPerBox {
            guard pk_nds_box_mon(handle, Int32(box), Int32(slot), &raw) else { continue }
            var mon = PKNDSMon()
            guard pk_nds_mon_decode(Int32(generation), raw, raw.count, &mon) else { continue }
            let species = Int(mon.species)
            result.append(BoxedMon(box: box, slot: slot, raw: Data(raw), species: species,
                                   speciesName: MonDetails.ndsSpeciesName(species),
                                   nickname: stringFromCField(mon.nickname),
                                   trainer: stringFromCField(mon.otName),
                                   isShiny: mon.isShiny, isEgg: mon.isEgg))
        }
        return result
    }

    func deposit(_ raw: Data) throws -> (box: Int, slot: Int) {
        var box: Int32 = 0
        var slot: Int32 = 0
        guard pk_nds_first_empty(handle, &box, &slot) else {
            throw NDSSaveError(code: Int32(PK_ERR_OCCUPIED))
        }
        guard raw.count == Self.monSize else {
            throw NDSSaveError(code: Int32(PK_ERR_INVALID_MON))
        }
        if let reason = missingFromGame(raw) {
            throw GameLacksError(reason: reason)
        }
        let code: Int32 = raw.withUnsafeBytes { bytes in
            pk_nds_put_box_mon(handle, box, slot, bytes.bindMemory(to: UInt8.self).baseAddress)
        }
        guard code == 0 else {
            throw NDSSaveError(code: code)
        }
        return (Int(box), Int(slot))
    }

    /// What of this Pokémon the game doesn't have (a ROM hack's Pokémon, move, talent or item past the official
    /// game's last one), or nil when it can go in. The saves the bank opens are the official games' layouts, so
    /// their limits are the official games'.
    private func missingFromGame(_ raw: Data) -> String? {
        var mon = PKNDSMon()
        let decoded = raw.withUnsafeBytes { bytes in
            pk_nds_mon_decode(Int32(generation), bytes.bindMemory(to: UInt8.self).baseAddress, raw.count, &mon)
        }
        guard decoded else { return nil }
        // An hg-engine hack holds every official Pokémon, move and talent: the core checks what's left.
        if isHgEngine { return nil }
        let gen5 = generation == 5
        let lastSpecies = gen5 ? 649 : 493, lastMove = gen5 ? 559 : 467
        let lastAbility = gen5 ? 164 : 123, lastItem = gen5 ? 638 : 536
        let species = Int(mon.storedSpecies)
        if species > lastSpecies {
            return "Ce Pokémon n'existe pas dans ce jeu."
        }
        let moves = [mon.moves.0, mon.moves.1, mon.moves.2, mon.moves.3].map(Int.init)
        if let move = moves.first(where: { $0 > lastMove }) {
            return "Il connaît une capacité (n° \(move)) qui n'existe pas dans ce jeu."
        }
        if Int(mon.ability) > lastAbility {
            return "Son talent n'existe pas dans ce jeu."
        }
        if Int(mon.heldItem) > lastItem {
            return "L'objet qu'il tient n'existe pas dans ce jeu : retire-le dans le jeu d'origine d'abord."
        }
        return nil
    }

    func remove(_ mon: BoxedMon) throws {
        let code = pk_nds_clear_box_mon(handle, Int32(mon.box), Int32(mon.slot))
        guard code == 0 else {
            throw NDSSaveError(code: code)
        }
    }

    func write() throws {
        if !backedUp {
            try SaveBackup.backUp(url)
            backedUp = true
        }
        let size = pk_nds_save_size(handle)
        var output = [UInt8](repeating: 0, count: size)
        guard size > 0, pk_nds_save_write(handle, &output, size) == size else {
            throw NDSSaveError(code: Int32(PK_ERR_SIZE))
        }
        try Data(output).write(to: url, options: .atomic)
    }

    func details(of mon: BoxedMon) -> MonDetails? {
        MonDetails.makeNDS(generation: generation, raw: mon.raw, sourceGame: sourceGame)
    }
}

struct NDSSaveError: LocalizedError {
    let code: Int32

    var errorDescription: String? {
        switch Int(code) {
        case Int(PK_ERR_SIZE): return "Ce fichier n'est pas une sauvegarde Pokémon DS (512 Ko attendus). Lance le jeu et sauvegarde une fois depuis son menu."
        case Int(PK_ERR_NO_SLOT): return "Ce fichier n'a pas le format d'une sauvegarde Pokémon Diamant, Perle, Platine, HeartGold, SoulSilver, Noire, Blanche, Noire 2 ou Blanche 2, ou la partie n'a pas encore été sauvegardée. Par prudence, la banque n'y touche pas."
        case Int(PK_ERR_CHECKSUM): return "Le PC de cette sauvegarde est abîmé (sommes de contrôle incorrectes). Par prudence, la banque n'y touche pas."
        case Int(PK_ERR_RANGE): return "Cette boîte n'est pas utilisable."
        case Int(PK_ERR_INVALID_MON): return "Ce Pokémon ne peut pas aller dans ce jeu : il est illisible, ou lui-même, son objet ou une de ses capacités n'existe pas dans ce jeu."
        case Int(PK_ERR_OCCUPIED): return "Plus de place dans les boîtes du PC."
        default: return "Erreur inconnue (\(code))."
        }
    }
}

extension NDSSaveFile {
    /// The team: National numbers and shiny.
    func teamSpecies() -> [(species: Int, shiny: Bool)] {
        let size = Int(PK_NDS_MON_SIZE)
        var buffer = [UInt8](repeating: 0, count: 6 * size)
        let count = Int(pk_nds_party(handle, &buffer))
        let generation = Int32(pk_nds_save_generation(handle))
        return (0..<count).compactMap { index in
            var mon = PKNDSMon()
            let ok = buffer[index * size..<(index + 1) * size].withUnsafeBufferPointer {
                pk_nds_mon_decode(generation, $0.baseAddress, $0.count, &mon)
            }
            return ok && !mon.isEgg && mon.species > 0 ? (Int(mon.species), mon.isShiny) : nil
        }
    }

    /// The game's own Pokédex: National numbers caught and seen.
    func pokedexFlags() -> (caught: Set<Int>, seen: Set<Int>)? {
        var caught = [UInt8](repeating: 0, count: Int(PK_DEX_FLAG_BYTES))
        var seen = caught
        guard pk_nds_pokedex(handle, &caught, &seen) else { return nil }
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

/// A Pokémon the target game doesn't have: it stays in the bank.
struct GameLacksError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason + " Il reste dans la banque." }
}
