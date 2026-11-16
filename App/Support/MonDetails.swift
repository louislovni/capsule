import Foundation

/// Everything worth showing about one Pokémon, in display form.
/// Codable so the bank can keep a copy made with the game the Pokémon came from.
struct MonDetails: Codable, Equatable {
    struct Move: Codable, Equatable {
        var name: String
        var pp: Int
    }

    /// 1 or 2 for the Game Boy games, 4 or 5 for the DS games; nil for the GBA games (generation 3).
    var generation: Int?
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
    var nature: String?
    /// Index into `stats` (1...5) of the stat the nature raises / lowers.
    var natureRaised: Int?
    var natureLowered: Int?
    var ability: String?
    var heldItem: String?
    var types: [String]
    var friendship: Int?
    var hiddenPower: String?

    /// Names of the rows of `stats`, `ivs` and `evs`; nil means `statNames`.
    var statLabels: [String]?
    /// HP, Attack, Defense, Speed, Sp. Atk, Sp. Def. Nil when the base stats are unknown.
    var stats: [Int]?
    var ivs: [Int]
    var evs: [Int]
    var currentHP: Int?
    var status: String?
    var moves: [Move]

    var trainerName: String
    var trainerGender: String?
    var trainerID: Int
    var secretID: Int?

    /// Nil when the game does not record it (everything before Crystal).
    var metLocation: String?
    /// 0 when the Pokémon hatched from an egg.
    var metLevel: Int?
    var metTime: String?
    var ball: String?
    /// DS games only: day of the encounter, and where and when the egg was received.
    var metDate: String?
    var eggLocation: String?
    var eggDate: String?
    var originGame: String
    var language: String?

    var pokerus: String?
    var ribbons: Int?
    var contest: [Int]?
    var personality: UInt32?

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

        generation = nil
        statLabels = nil
        metTime = nil
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

    // MARK: - Game Boy games

    static let gbTypeNames: [Int: String] = [
        0: "Normal", 1: "Combat", 2: "Vol", 3: "Poison", 4: "Sol", 5: "Roche", 7: "Insecte", 8: "Spectre",
        9: "Acier", 20: "Feu", 21: "Eau", 22: "Plante", 23: "Électrik", 24: "Psy", 25: "Glace", 26: "Dragon",
        27: "Ténèbres",
    ]

    static func gbSpeciesName(_ dex: Int) -> String {
        pk_gb_species_name(UInt32(max(dex, 0))).map { String(cString: $0) } ?? "Pokémon n°\(dex)"
    }

    static func gbMoveName(_ id: Int) -> String {
        pk_gb_move_name(UInt32(max(id, 0))).map { String(cString: $0) } ?? "Capacité n°\(id)"
    }

    static func gbItemName(_ id: Int) -> String {
        pk_gb_item_name(UInt32(max(id, 0))).map { String(cString: $0) } ?? "Objet n°\(id)"
    }

    static func gbLandmarkName(_ id: Int) -> String? {
        pk_gb_landmark_name(UInt32(max(id, 0))).map { String(cString: $0) }
    }

    /// Size of the structure at the start of a Game Boy blob: box or party.
    static func gbStructureSize(generation: Int, party: Bool) -> Int {
        if generation == 1 {
            return party ? Int(PK_GB1_PARTY_MON) : Int(PK_GB1_BOX_MON)
        }
        return party ? Int(PK_GB2_PARTY_MON) : Int(PK_GB2_BOX_MON)
    }

    /// Decodes a Game Boy Pokémon kept as: structure (box or party size), trainer
    /// name, nickname, species-list byte.
    static func decodeGB(generation: Int, raw: Data, party: Bool) -> PKGBMon? {
        let size = gbStructureSize(generation: generation, party: party)
        let names = Int(PK_GB_NAME_LENGTH)
        guard raw.count >= size + 2 * names + 1 else { return nil }
        var mon = PKGBMon()
        let ok = raw.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return false }
            return pk_gb_mon_decode(Int32(generation), base, size, base + size, base + size + names,
                                    base[size + 2 * names], &mon)
        }
        return ok ? mon : nil
    }

    static func makeGB(generation: Int, raw: Data, party: Bool, sourceGame: String) -> MonDetails? {
        guard let mon = decodeGB(generation: generation, raw: raw, party: party) else { return nil }
        return MonDetails(gb: mon, sourceGame: sourceGame)
    }

    private init(gb mon: PKGBMon, sourceGame: String) {
        let generation = Int(mon.generation)
        let dex = Int(mon.dex)
        let dvs = bytes(of: mon.dvs, count: 5).map(Int.init)
        let statExp = words(of: mon.statExp, count: 5)
        var baseStats = [UInt8](repeating: 0, count: 6)
        var type1: UInt8 = 0
        var type2: UInt8 = 0
        var growth: UInt8 = 0
        let hasBase = pk_gb_base_stats(Int32(generation), UInt32(dex), &baseStats, &type1, &type2, nil, &growth)

        self.generation = generation
        species = dex
        speciesName = Self.gbSpeciesName(dex)
        nationalDex = dex
        nickname = stringFromCField(mon.nickname)
        isEgg = mon.isEgg
        isShiny = mon.isShiny
        if generation == 2 {
            var dvBytes = dvs.map { UInt8($0) }
            switch pk_gb_gender(UInt32(dex), &dvBytes) {
            case 0: gender = "♂"
            case 1: gender = "♀"
            default: gender = nil
            }
        } else {
            gender = nil
        }

        level = Int(mon.level)
        experience = Int(mon.experience)
        if hasBase && level < 100 {
            experienceToNext = max(Int(pk_exp_for_level(growth, UInt32(level + 1))) - experience, 0)
        } else {
            experienceToNext = nil
        }
        nature = nil
        natureRaised = nil
        natureLowered = nil
        ability = nil
        heldItem = generation == 2 && mon.heldItem != 0 ? Self.gbItemName(Int(mon.heldItem)) : nil
        if hasBase {
            var list = [Self.gbTypeNames[Int(type1)] ?? "Type n°\(type1)"]
            if type2 != type1 {
                list.append(Self.gbTypeNames[Int(type2)] ?? "Type n°\(type2)")
            }
            types = list
        } else {
            types = []
        }
        if generation == 2 {
            friendship = Int(mon.friendship)
            var dvBytes = dvs.map { UInt8($0) }
            var hpType: UInt8 = 0
            var hpPower: UInt8 = 0
            pk_gb_hidden_power(&dvBytes, &hpType, &hpPower)
            hiddenPower = "\(Self.hiddenPowerTypes[Int(hpType) % 16]) \(hpPower)"
        } else {
            friendship = nil
            hiddenPower = nil
        }

        let rows = generation == 1 ? 5 : 6
        statLabels = generation == 1 ? ["PV", "Attaque", "Défense", "Vitesse", "Spécial"] : nil
        // Generation 2 uses the Special DV and stat experience for both special stats.
        ivs = Array((dvs + [dvs[4]]).prefix(rows))
        evs = Array((statExp + [statExp[4]]).prefix(rows))
        let partyStats = words(of: mon.stats, count: 6)
        if mon.hasPartyData && partyStats[0] > 0 {
            stats = Array(partyStats.prefix(rows))
            currentHP = Int(mon.hp)
            status = MonSummary.statusLabel(status: UInt32(mon.status), hp: Int(mon.hp), maxHp: partyStats[0])
        } else if hasBase && level > 0 {
            var dvBytes = dvs.map { UInt8($0) }
            var expValues = statExp.map { UInt16($0) }
            var out = [UInt16](repeating: 0, count: 6)
            pk_gb_calc_stats(Int32(generation), UInt32(dex), &dvBytes, &expValues, UInt32(level), &out)
            stats = Array(out.map(Int.init).prefix(rows))
            currentHP = nil
            status = nil
        } else {
            stats = nil
            currentHP = nil
            status = nil
        }

        let moveIDs = bytes(of: mon.moves, count: 4)
        let pp = bytes(of: mon.pp, count: 4)
        moves = zip(moveIDs, pp).compactMap { id, pp in
            id == 0 ? nil : Move(name: Self.gbMoveName(Int(id)), pp: Int(pp))
        }

        trainerName = stringFromCField(mon.otName)
        trainerID = Int(mon.otId)
        secretID = nil
        if mon.hasCaughtData {
            trainerGender = mon.otGender == 1 ? "♀" : "♂"
            metLevel = Int(mon.metLevel)
            metLocation = Self.gbLandmarkName(Int(mon.metLocation)) ?? "Lieu n°\(mon.metLocation)"
            switch mon.metTime {
            case 1: metTime = "Matin"
            case 2: metTime = "Jour"
            case 3: metTime = "Nuit"
            default: metTime = nil
            }
        } else {
            trainerGender = nil
            metLevel = nil
            metLocation = nil
            metTime = nil
        }
        ball = nil
        originGame = sourceGame
        language = nil
        if generation == 2 && mon.pokerus != 0 {
            pokerus = mon.pokerus & 0x0F != 0 ? "Porteur" : "Guéri (immunisé)"
        } else {
            pokerus = nil
        }
        ribbons = nil
        contest = nil
        personality = nil
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

// MARK: - DS games (generations 4 and 5)

extension MonDetails {
    static func ndsSpeciesName(_ dex: Int) -> String {
        pk_nds_species_name(UInt32(dex)).map { String(cString: $0) } ?? "Pokémon n°\(dex)"
    }

    static let ndsGameNames = [
        1: "Saphir", 2: "Rubis", 3: "Émeraude", 4: "Rouge Feu", 5: "Vert Feuille", 7: "Or HeartGold",
        8: "Argent SoulSilver", 10: "Diamant", 11: "Perle", 12: "Platine", 15: "Colosseum / XD",
        20: "Blanche", 21: "Noire", 22: "Blanche 2", 23: "Noire 2",
    ]

    static let ndsLanguageNames = [
        1: "Japonais", 2: "Anglais", 3: "Français", 4: "Italien", 5: "Allemand", 7: "Espagnol", 8: "Coréen",
    ]

    /// Decodes a 136-byte structure of the DS games, as kept in a save and in the bank.
    static func makeNDS(generation: Int, raw: Data, sourceGame: String) -> MonDetails? {
        var mon = PKNDSMon()
        let ok = raw.withUnsafeBytes { bytes in
            pk_nds_mon_decode(Int32(generation), bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &mon)
        }
        guard ok else { return nil }
        return MonDetails(nds: mon, sourceGame: sourceGame)
    }

    private static func ndsDate(year: UInt8, month: UInt8, day: UInt8) -> String? {
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        return String(format: "%02d/%02d/%04d", Int(day), Int(month), 2000 + Int(year))
    }

    private static func ndsLocation(generation: Int, _ location: UInt16) -> String? {
        guard location != 0 else { return nil }
        return pk_nds_location_name(Int32(generation), UInt32(location)).map { String(cString: $0) }
            ?? "Lieu n°\(location)"
    }

    private init(nds mon: PKNDSMon, sourceGame: String) {
        let generation = Int(mon.generation)
        let dex = Int(mon.species)
        var baseValue = PKNDSBase()
        let base: PKNDSBase? = pk_nds_base_stats(UInt32(dex), &baseValue) ? baseValue : nil
        let ivList = bytes(of: mon.ivs, count: 6)
        let evList = bytes(of: mon.evs, count: 6)

        self.generation = generation
        statLabels = nil
        metTime = nil
        species = dex
        speciesName = Self.ndsSpeciesName(dex)
        nationalDex = dex
        nickname = stringFromCField(mon.nickname)
        isEgg = mon.isEgg
        isShiny = mon.isShiny
        switch mon.gender {
        case 0: gender = "♂"
        case 1: gender = "♀"
        default: gender = nil
        }

        experience = Int(mon.experience)
        level = Int(pk_nds_level(UInt32(dex), mon.experience))
        if let base = base, level > 0, level < 100 {
            experienceToNext = max(Int(pk_exp_for_level(base.growthRate, UInt32(level + 1))) - experience, 0)
        } else {
            experienceToNext = nil
        }

        let natureIndex = Int(mon.nature) % 25
        nature = Self.natureNames[natureIndex]
        var raised: Int32 = -1
        var lowered: Int32 = -1
        pk_nature_effect(UInt32(natureIndex), &raised, &lowered)
        natureRaised = raised >= 0 ? Int(raised) + 1 : nil
        natureLowered = lowered >= 0 ? Int(lowered) + 1 : nil

        let abilityName = pk_nds_ability_name(UInt32(mon.ability)).map { String(cString: $0) } ?? "Talent n°\(mon.ability)"
        ability = mon.hiddenAbility ? "\(abilityName) (talent caché)" : abilityName
        heldItem = mon.heldItem == 0 ? nil
            : pk_nds_item_name(UInt32(mon.heldItem)).map { String(cString: $0) } ?? "Objet n°\(mon.heldItem)"
        if let base = base {
            let typeName = { (index: UInt8) -> String in
                pk_nds_type_name(UInt32(index)).map { String(cString: $0) } ?? "?"
            }
            types = base.type1 == base.type2 ? [typeName(base.type1)] : [typeName(base.type1), typeName(base.type2)]
        } else {
            types = []
        }
        friendship = mon.isEgg ? nil : Int(mon.friendship)
        hiddenPower = "\(Self.hiddenPowerTypes[Int(mon.hiddenPowerType) % 16]) \(mon.hiddenPowerPower)"

        ivs = ivList.map(Int.init)
        evs = evList.map(Int.init)
        var ivBytes = ivList
        var evBytes = evList
        var out = [UInt16](repeating: 0, count: 6)
        if level > 0, pk_nds_calc_stats(UInt32(dex), &ivBytes, &evBytes, UInt32(level), UInt32(natureIndex), &out) {
            stats = out.map(Int.init)
        } else {
            stats = nil
        }
        currentHP = nil
        status = nil

        let moveIDs = words(of: mon.moves, count: 4)
        let pp = bytes(of: mon.pp, count: 4)
        moves = zip(moveIDs, pp).compactMap { id, pp in
            id == 0 ? nil : Move(name: pk_nds_move_name(UInt32(id)).map { String(cString: $0) } ?? "Capacité n°\(id)",
                                 pp: Int(pp))
        }

        trainerName = stringFromCField(mon.otName)
        trainerGender = mon.otGender == 1 ? "♀" : "♂"
        trainerID = Int(mon.tid)
        secretID = Int(mon.sid)

        metLocation = Self.ndsLocation(generation: generation, mon.metLocation)
        metLevel = Int(mon.metLevel)
        metDate = Self.ndsDate(year: mon.metYear, month: mon.metMonth, day: mon.metDay)
        eggLocation = Self.ndsLocation(generation: generation, mon.eggLocation)
        eggDate = mon.eggLocation != 0 ? Self.ndsDate(year: mon.eggYear, month: mon.eggMonth, day: mon.eggDay) : nil
        ball = pk_nds_ball_name(UInt32(mon.ball)).map { String(cString: $0) }
        originGame = Self.ndsGameNames[Int(mon.originGame)] ?? sourceGame
        language = Self.ndsLanguageNames[Int(mon.language)]

        if mon.pokerus == 0 {
            pokerus = nil
        } else {
            pokerus = mon.pokerus & 0x0F != 0 ? "Porteur" : "Guéri (immunisé)"
        }
        ribbons = Int(mon.ribbonCount)
        contest = bytes(of: mon.contest, count: 6).map(Int.init)
        personality = mon.personality
    }
}

/// Reads the first `count` bytes of a C array field (imported as a tuple).
private func bytes<T>(of tuple: T, count: Int) -> [UInt8] {
    withUnsafeBytes(of: tuple) { raw in
        Array(raw.prefix(count))
    }
}

/// Reads the first `count` 16-bit values of a C array field (imported as a tuple).
private func words<T>(of tuple: T, count: Int) -> [Int] {
    withUnsafeBytes(of: tuple) { raw -> [Int] in
        let values = raw.bindMemory(to: UInt16.self)
        return (0..<min(count, values.count)).map { Int(values[$0]) }
    }
}
