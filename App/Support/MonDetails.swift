import Foundation

/// Everything worth showing about one Pokémon, in display form.
/// Codable so the bank can keep a copy made with the game the Pokémon came from.
struct MonDetails: Codable, Equatable {
    struct Move: Codable, Equatable {
        var name: String
        var pp: Int
    }

    var species: Int
    var speciesName: String
    var nationalDex: Int?
    var nickname: String
    var isEgg: Bool
    var isShiny: Bool
    /// "♂", "♀", or nil when genderless or unknown.
    var gender: String?

    var level: Int
    var experience: Int
    /// Experience still needed for the next level; nil at level 100 or when unknown.
    var experienceToNext: Int?
    var nature: String
    /// Index into `stats` (1...5) of the stat the nature raises / lowers.
    var natureRaised: Int?
    var natureLowered: Int?
    var ability: String?
    var heldItem: String?
    var types: [String]
    var friendship: Int
    var hiddenPower: String

    /// HP, Attack, Defense, Speed, Sp. Atk, Sp. Def. Nil when the base stats are unknown.
    var stats: [Int]?
    var ivs: [Int]
    var evs: [Int]
    var currentHP: Int?
    var status: String?
    var moves: [Move]

    var trainerName: String
    var trainerGender: String
    var trainerID: Int
    var secretID: Int

    var metLocation: String
    /// 0 when the Pokémon hatched from an egg.
    var metLevel: Int
    var ball: String
    var originGame: String
    var language: String

    var pokerus: String?
    var ribbons: Int
    var contest: [Int]
    var personality: UInt32

    // MARK: - Labels

    static let statNames = ["PV", "Attaque", "Défense", "Vitesse", "Atq. Spé.", "Déf. Spé."]
    static let contestNames = ["Sang-froid", "Beauté", "Grâce", "Intelligence", "Robustesse", "Lustre"]

    static let natureNames = [
        "Hardi", "Solo", "Brave", "Rigide", "Mauvais",
        "Assuré", "Docile", "Relax", "Malin", "Lâche",
        "Timide", "Pressé", "Sérieux", "Jovial", "Naïf",
        "Modeste", "Doux", "Discret", "Pudique", "Foufou",
        "Calme", "Gentil", "Malpoli", "Prudent", "Bizarre",
    ]

    /// Type ids of the GBA games (9 is an unused slot).
    static let typeNames = [
        "Normal", "Combat", "Vol", "Poison", "Sol", "Roche", "Insecte", "Spectre", "Acier", "???",
        "Feu", "Eau", "Plante", "Électrik", "Psy", "Glace", "Dragon", "Ténèbres",
    ]

    /// Hidden Power types, in the order of the formula.
    static let hiddenPowerTypes = [
        "Combat", "Vol", "Poison", "Sol", "Roche", "Insecte", "Spectre", "Acier",
        "Feu", "Eau", "Plante", "Électrik", "Psy", "Glace", "Dragon", "Ténèbres",
    ]

    static let ballNames = [
        1: "Master Ball", 2: "Hyper Ball", 3: "Super Ball", 4: "Poké Ball", 5: "Safari Ball", 6: "Filet Ball",
        7: "Scuba Ball", 8: "Faiblo Ball", 9: "Bis Ball", 10: "Chrono Ball", 11: "Luxe Ball", 12: "Honor Ball",
    ]

    static let gameNames = [
        1: "Saphir", 2: "Rubis", 3: "Émeraude", 4: "Rouge Feu", 5: "Vert Feuille", 15: "Colosseum / XD",
    ]

    static let languageNames = [
        1: "Japonais", 2: "Anglais", 3: "Français", 4: "Italien", 5: "Allemand", 7: "Espagnol",
    ]

    // MARK: - Building

    /// Decodes an 80-byte (PC, bank) or 100-byte (team) structure. Names and
    /// computed values come from `rom` when given; without it, numbers are shown.
    static func make(raw: Data, rom: RomData?) -> MonDetails? {
        var mon = PKMon()
        let decoded = raw.withUnsafeBytes { bytes in
            pk_mon_decode(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &mon)
        }
        guard decoded else { return nil }
        return MonDetails(mon: mon, rom: rom)
    }

    private init(mon: PKMon, rom: RomData?) {
        let summary = MonSummary(mon)
        let ivList = bytes(of: mon.ivs, count: 6).map(Int.init)
        let evList = bytes(of: mon.evs, count: 6).map(Int.init)
        let base = rom?.baseStats(species: summary.species)

        species = summary.species
        speciesName = rom?.speciesName(summary.species) ?? "Pokémon n°\(summary.species)"
        nationalDex = rom?.nationalDex(species: summary.species)
        nickname = summary.nickname
        isEgg = summary.isEgg
        isShiny = summary.isShiny

        experience = Int(mon.experience)
        if mon.hasPartyData && mon.level > 0 {
            level = Int(mon.level)
        } else if let base = base {
            level = Int(pk_level_for_exp(base.growthRate, mon.experience))
        } else {
            level = 0
        }
        if let base = base, level > 0, level < 100 {
            let next = Int(pk_exp_for_level(base.growthRate, UInt32(level + 1)))
            experienceToNext = max(next - experience, 0)
        } else {
            experienceToNext = nil
        }

        let natureIndex = Int(mon.nature)
        nature = Self.natureNames[natureIndex % 25]
        var raised: Int32 = -1
        var lowered: Int32 = -1
        pk_nature_effect(UInt32(natureIndex), &raised, &lowered)
        natureRaised = raised >= 0 ? Int(raised) + 1 : nil
        natureLowered = lowered >= 0 ? Int(lowered) + 1 : nil

        if let base = base {
            switch pk_gender(mon.personality, base.genderRatio) {
            case 0: gender = "♂"
            case 1: gender = "♀"
            default: gender = nil
            }
            let abilityIndex = mon.abilityBit == 1 && base.ability2 != 0 ? base.ability2 : base.ability1
            ability = rom?.abilityName(Int(abilityIndex)) ?? "Talent n°\(abilityIndex)"
            var typeList = [Self.typeName(Int(base.type1))]
            if base.type2 != base.type1 {
                typeList.append(Self.typeName(Int(base.type2)))
            }
            types = typeList
        } else {
            gender = nil
            ability = nil
            types = []
        }

        if mon.heldItem != 0 {
            heldItem = rom?.itemName(Int(mon.heldItem)) ?? "Objet n°\(mon.heldItem)"
        } else {
            heldItem = nil
        }
        friendship = Int(mon.friendship)
        hiddenPower = "\(Self.hiddenPowerTypes[Int(mon.hiddenPowerType) % 16]) \(mon.hiddenPowerPower)"

        if mon.hasPartyData && mon.maxHp > 0 {
            stats = [Int(mon.maxHp), Int(mon.attack), Int(mon.defense), Int(mon.speed), Int(mon.spAttack), Int(mon.spDefense)]
            currentHP = Int(mon.hp)
            status = summary.statusLabel
        } else if var base = base, level > 0 {
            var ivBytes = ivList.map { UInt8($0) }
            var evBytes = evList.map { UInt8($0) }
            var out = [UInt16](repeating: 0, count: 6)
            pk_calc_stats(&base, &ivBytes, &evBytes, UInt32(level), UInt32(natureIndex), UInt16(summary.species), &out)
            stats = out.map(Int.init)
            currentHP = nil
            status = nil
        } else {
            stats = nil
            currentHP = nil
            status = nil
        }
        ivs = ivList
        evs = evList

        let moveIDs = [mon.moves.0, mon.moves.1, mon.moves.2, mon.moves.3]
        let ppValues = [mon.pp.0, mon.pp.1, mon.pp.2, mon.pp.3]
        moves = zip(moveIDs, ppValues).compactMap { id, pp in
            guard id != 0 else { return nil }
            return Move(name: rom?.moveName(Int(id)) ?? "Capacité n°\(id)", pp: Int(pp))
        }

        trainerName = summary.trainerName
        trainerGender = mon.otGender == 1 ? "♀" : "♂"
        trainerID = Int(mon.otId & 0xFFFF)
        secretID = Int(mon.otId >> 16)

        metLevel = Int(mon.metLevel)
        let location = Int(mon.metLocation)
        switch location {
        case 0xFD:
            metLocation = "Œuf reçu en cadeau"
        case 0xFE:
            metLocation = "Échange dans le jeu"
        case 0xFF:
            metLocation = "Rencontre fatidique (distribution)"
        default:
            if mon.originGame == 15 {
                metLocation = "Région d'Orre"
            } else {
                metLocation = rom?.locationName(location) ?? "Lieu n°\(location)"
            }
        }
        let ballID = Int(mon.ball)
        ball = rom?.itemName(ballID).flatMap { ballID >= 1 && ballID <= 12 ? $0 : nil }
            ?? Self.ballNames[ballID] ?? "Ball n°\(ballID)"
        originGame = Self.gameNames[Int(mon.originGame)] ?? "Jeu n°\(mon.originGame)"
        language = Self.languageNames[Int(mon.language)] ?? "Langue n°\(mon.language)"

        if mon.pokerus == 0 {
            pokerus = nil
        } else if mon.pokerus & 0x0F != 0 {
            pokerus = "Porteur"
        } else {
            pokerus = "Guéri (immunisé)"
        }
        ribbons = Int(pk_ribbon_count(mon.ribbons))
        contest = bytes(of: mon.contest, count: 6).map(Int.init)
        personality = mon.personality
    }

    private static func typeName(_ id: Int) -> String {
        id >= 0 && id < typeNames.count ? typeNames[id] : "Type n°\(id)"
    }

    // MARK: - Display helpers

    var displayName: String {
        if isEgg { return "Œuf" }
        if nickname.isEmpty || nickname.caseInsensitiveCompare(speciesName) == .orderedSame {
            return speciesName
        }
        return "\(nickname) (\(speciesName))"
    }

    var natureEffect: String {
        guard let up = natureRaised, let down = natureLowered else { return "neutre" }
        return "+\(Self.statNames[up]), −\(Self.statNames[down])"
    }
}

/// Reads the first `count` bytes of a C array field (imported as a tuple).
private func bytes<T>(of tuple: T, count: Int) -> [UInt8] {
    withUnsafeBytes(of: tuple) { raw in
        Array(raw.prefix(count))
    }
}
