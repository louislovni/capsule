import Foundation

/// Evolution by trade: what happens to a Pokémon received from a friend, as in the games.
/// Held item rules: the item is used up; an Everstone stops any evolution.
enum TradeEvolution {
    private struct Rule {
        /// National Pokédex numbers.
        let from: Int
        let to: Int
        /// Held item it needs, as National item numbers of generation 4 and 5 (mapped for older games).
        var item: Item? = nil
        /// The Pokémon it must be traded for (Karrablast and Shelmet).
        var partner: Int? = nil
        /// Generation 4 and 5 store the ability: old ability number → new one, when it changes.
        var abilities: [Int: Int] = [:]
        /// First generation where it exists.
        var since: Int = 1
    }

    private enum Item {
        case kingsRock, metalCoat, dragonScale, upGrade, deepSeaTooth, deepSeaScale
        case protector, electirizer, magmarizer, dubiousDisc, reaperCloth

        /// Item number in a game of this generation, nil when it doesn't exist there.
        func number(generation: Int) -> Int? {
            switch generation {
            case 2:
                switch self {
                case .kingsRock: return 82
                case .metalCoat: return 143
                case .dragonScale: return 151
                case .upGrade: return 172
                default: return nil
                }
            case 3:
                switch self {
                case .kingsRock: return 187
                case .deepSeaTooth: return 192
                case .deepSeaScale: return 193
                case .metalCoat: return 199
                case .dragonScale: return 201
                case .upGrade: return 218
                default: return nil
                }
            case 4, 5:
                switch self {
                case .kingsRock: return 221
                case .deepSeaTooth: return 226
                case .deepSeaScale: return 227
                case .metalCoat: return 233
                case .dragonScale: return 235
                case .upGrade: return 252
                case .protector: return 321
                case .electirizer: return 322
                case .magmarizer: return 323
                case .dubiousDisc: return 324
                case .reaperCloth: return 325
                }
            default:
                return nil
            }
        }
    }

    private static func everstone(generation: Int) -> Int? {
        switch generation {
        case 2: return 112
        case 3: return 195
        case 4, 5: return 229
        default: return nil
        }
    }

    // Ability numbers (generations 4 and 5).
    private static let swiftSwim = 33, poisonPoint = 38, trace = 36, adaptability = 91, shellArmor = 75
    private static let rockHead = 69, solidRock = 116, staticAbility = 9, motorDrive = 78, shedSkin = 61
    private static let stickyHold = 60, noGuard = 99, overcoat = 142, unburden = 84

    private static let rules: [Rule] = [
        Rule(from: 64, to: 65),   // Kadabra → Alakazam
        Rule(from: 67, to: 68),   // Machoke → Machamp
        Rule(from: 75, to: 76),   // Graveler → Golem
        Rule(from: 93, to: 94),   // Haunter → Gengar
        Rule(from: 61, to: 186, item: .kingsRock, since: 2),   // Poliwhirl → Politoed
        Rule(from: 79, to: 199, item: .kingsRock, since: 2),   // Slowpoke → Slowking
        Rule(from: 95, to: 208, item: .metalCoat, since: 2),   // Onix → Steelix
        Rule(from: 123, to: 212, item: .metalCoat, since: 2),  // Scyther → Scizor
        Rule(from: 117, to: 230, item: .dragonScale, abilities: [poisonPoint: swiftSwim], since: 2), // Seadra → Kingdra
        Rule(from: 137, to: 233, item: .upGrade, since: 2),    // Porygon → Porygon2
        Rule(from: 366, to: 367, item: .deepSeaTooth, abilities: [shellArmor: swiftSwim], since: 3),  // Clamperl → Huntail
        Rule(from: 366, to: 368, item: .deepSeaScale, abilities: [shellArmor: swiftSwim], since: 3),  // Clamperl → Gorebyss
        Rule(from: 112, to: 464, item: .protector, abilities: [rockHead: solidRock], since: 4),     // Rhydon → Rhyperior
        Rule(from: 125, to: 466, item: .electirizer, abilities: [staticAbility: motorDrive], since: 4), // Electabuzz → Electivire
        Rule(from: 126, to: 467, item: .magmarizer, since: 4), // Magmar → Magmortar
        Rule(from: 233, to: 474, item: .dubiousDisc, abilities: [trace: adaptability], since: 4),  // Porygon2 → Porygon-Z
        Rule(from: 356, to: 477, item: .reaperCloth, since: 4), // Dusclops → Dusknoir
        Rule(from: 588, to: 589, partner: 616, abilities: [shedSkin: shellArmor, noGuard: overcoat], since: 5), // Karrablast → Escavalier
        Rule(from: 616, to: 617, partner: 588, abilities: [shellArmor: stickyHold, overcoat: unburden], since: 5), // Shelmet → Accelgor
        Rule(from: 525, to: 526, since: 5), // Boldore → Gigalith
        Rule(from: 533, to: 534, since: 5), // Gurdurr → Conkeldurr
    ]

    // Generation 3 numbers its Hoenn species its own way.
    private static let gen3Index: [Int: Int] = [366: 373, 367: 374, 368: 375]

    private static func gen3Dex(_ index: Int) -> Int {
        gen3Index.first(where: { $0.value == index })?.key ?? index
    }

    /// National Pokédex number of a bank entry (nil when unknown).
    static func nationalDex(of entry: BankEntry) -> Int? {
        if let dex = entry.details?.nationalDex { return dex }
        switch entry.effectiveGeneration {
        case 3: return entry.species <= 251 || gen3Index.values.contains(entry.species) ? gen3Dex(entry.species) : nil
        default: return entry.species
        }
    }

    private static func heldItem(of entry: BankEntry) -> Int? {
        var raw = [UInt8](entry.data)
        switch entry.effectiveGeneration {
        case 1:
            return 0
        case 2:
            return Int(raw[1])
        case 3:
            var mon = PKMon()
            return pk_mon_decode(&raw, raw.count, &mon) ? Int(mon.heldItem) : nil
        default:
            var mon = PKNDSMon()
            return pk_nds_mon_decode(Int32(entry.effectiveGeneration), &raw, raw.count, &mon) ? Int(mon.heldItem) : nil
        }
    }

    private static func ability(of entry: BankEntry) -> Int? {
        var raw = [UInt8](entry.data)
        var mon = PKNDSMon()
        return pk_nds_mon_decode(Int32(entry.effectiveGeneration), &raw, raw.count, &mon) ? Int(mon.ability) : nil
    }

    /// The received Pokémon after the trade: evolved when it should, otherwise unchanged.
    /// `partnerDex`: National Pokédex number of the Pokémon given for it.
    static func apply(to entry: BankEntry, partnerDex: Int?) -> BankEntry {
        let generation = entry.effectiveGeneration
        guard !entry.isEgg, let dex = nationalDex(of: entry), let item = heldItem(of: entry) else { return entry }
        if let stone = everstone(generation: generation), item == stone { return entry }
        guard let rule = rules.first(where: { rule in
            guard rule.from == dex, generation >= rule.since else { return false }
            if let needed = rule.item {
                guard let number = needed.number(generation: generation), number == item else { return false }
            }
            if let wanted = rule.partner, wanted != partnerDex { return false }
            return true
        }) else { return entry }
        return evolve(entry, rule: rule, keepItem: rule.item == nil) ?? entry
    }

    private static func evolve(_ entry: BankEntry, rule: Rule, keepItem: Bool) -> BankEntry? {
        let generation = entry.effectiveGeneration
        var raw = [UInt8](entry.data)
        var result = entry
        let unnamed = entry.nickname.isEmpty
            || entry.nickname.compare(entry.speciesName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        let shouted = !entry.nickname.isEmpty && entry.nickname == entry.nickname.uppercased()

        switch generation {
        case 1, 2:
            guard let cName = pk_gb_species_name(UInt32(rule.to)) else { return nil }
            let name = String(cString: cName)
            let gameName = name.uppercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
            let item = keepItem ? -1 : 0
            let ok = gameName.withCString { text in
                pk_gb_blob_set_species(Int32(generation), &raw, raw.count, UInt32(rule.to), Int32(item), unnamed ? text : nil)
            }
            guard ok else { return nil }
            result.data = Data(raw)
            result.species = rule.to
            result.speciesName = name
            if unnamed { result.nickname = gameName }
            result.details = MonDetails.makeGB(generation: generation, raw: result.data, party: false, sourceGame: entry.sourceGame)

        case 3:
            let index = gen3Index[rule.to] ?? rule.to
            var item = 0
            if keepItem, let held = heldItem(of: entry) { item = held }
            guard pk_mon_set_species(&raw, raw.count, UInt16(index), UInt16(item)) else { return nil }
            let rom = RomData.anyROM(preferring: entry.sourceGame)
            if unnamed, let name = rom?.rawSpeciesName(index) {
                for i in 0..<10 { raw[8 + i] = i < name.count ? name[i] : 0xFF }
            }
            result.data = Data(raw)
            result.species = index
            let ndsName = pk_nds_species_name(UInt32(rule.to)).map { String(cString: $0) }
            result.speciesName = rom?.speciesName(index) ?? ndsName ?? "Pokémon n°\(rule.to)"
            if unnamed, rom != nil { result.nickname = result.speciesName }
            result.details = MonDetails.make(raw: result.data, rom: rom)

        default:
            guard let cName = pk_nds_species_name(UInt32(rule.to)) else { return nil }
            let name = String(cString: cName)
            let shown = shouted ? name.uppercased() : name
            var item = 0
            if keepItem, let held = heldItem(of: entry) { item = held }
            let newAbility = ability(of: entry).flatMap { rule.abilities[$0] } ?? -1
            let ok = shown.withCString { text in
                pk_nds_set_species(Int32(generation), &raw, UInt16(rule.to), UInt16(item), Int32(newAbility),
                                   unnamed ? text : nil)
            }
            guard ok else { return nil }
            result.data = Data(raw)
            result.species = rule.to
            result.speciesName = name
            if unnamed { result.nickname = shown }
            result.details = MonDetails.makeNDS(generation: generation, raw: result.data, sourceGame: entry.sourceGame)
        }
        return result
    }
}

extension TradeEvolution {
    /// "Alakazam, qui a évolué depuis Kadabra," or just the name, to slot into "… a rejoint ta banque".
    static func describe(_ outcome: (entry: BankEntry, evolvedFrom: String?)) -> String {
        guard let from = outcome.evolvedFrom else { return outcome.entry.displayName }
        return "\(outcome.entry.displayName), qui a évolué depuis \(from),"
    }
}
