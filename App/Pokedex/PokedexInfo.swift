import Foundation

/// Species facts bundled with the app (pokedex-data.json, made by tools/gen_pokedex_data.py from
/// PokeAPI): size, category, abilities, evolutions and where to catch them in generations 1-5.
struct PokedexInfo {
    struct Ability {
        let name: String
        let hidden: Bool
    }

    struct Place: Identifiable {
        let location: String
        let method: String
        let minLevel: Int
        let maxLevel: Int
        var id: String { location + method }
        var levels: String { minLevel == maxLevel ? "Nv. \(minLevel)" : "Nv. \(minLevel)-\(maxLevel)" }
    }

    struct Species {
        let dex: Int
        let height: Int // decimetres
        let weight: Int // hectograms
        let category: String
        let abilities: [Ability]
        let chain: Int
        let previous: Int?
        let how: String?
        /// Game (version id) → places.
        let places: [Int: [Place]]

        var heightText: String { String(format: "%.1f m", Double(height) / 10).replacingOccurrences(of: ".", with: ",") }
        var weightText: String { String(format: "%.1f kg", Double(weight) / 10).replacingOccurrences(of: ".", with: ",") }
    }

    /// Version ids in the games' order, with their French names.
    let versions: [(id: Int, name: String)]
    private let species: [Species]

    static let shared = PokedexInfo()

    private init() {
        guard let url = Bundle.main.url(forResource: "pokedex-data", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["species"] as? [[String: Any]] else {
            versions = []
            species = []
            return
        }
        let names = root["versions"] as? [String: String] ?? [:]
        versions = names.compactMap { key, value in Int(key).map { ($0, value) } }.sorted { $0.id < $1.id }
        species = list.enumerated().map { index, item in
            let abilities: [Ability] = (item["a"] as? [Any] ?? []).compactMap { value in
                if let name = value as? String { return Ability(name: name, hidden: false) }
                if let pair = value as? [Any], let name = pair.first as? String { return Ability(name: name, hidden: true) }
                return nil
            }
            var places: [Int: [Place]] = [:]
            for (key, value) in item["where"] as? [String: [[Any]]] ?? [:] {
                guard let version = Int(key) else { continue }
                places[version] = value.compactMap { row in
                    guard row.count == 4, let location = row[0] as? String, let method = row[1] as? String,
                          let low = row[2] as? Int, let high = row[3] as? Int else { return nil }
                    return Place(location: location, method: method, minLevel: low, maxLevel: high)
                }
            }
            return Species(dex: index + 1, height: item["h"] as? Int ?? 0, weight: item["w"] as? Int ?? 0,
                           category: item["c"] as? String ?? "", abilities: abilities, chain: item["chain"] as? Int ?? 0,
                           previous: item["pre"] as? Int, how: item["how"] as? String, places: places)
        }
    }

    func species(_ dex: Int) -> Species? {
        dex >= 1 && dex <= species.count ? species[dex - 1] : nil
    }

    /// The evolution family, as stages: [[Bulbizarre], [Herbizarre], [Florizarre]]; branches share a stage.
    func family(of dex: Int) -> [[Species]] {
        guard let me = species(dex) else { return [] }
        let members = species.filter { $0.chain == me.chain }
        guard members.count > 1 else { return [] }
        var stages: [[Species]] = [members.filter { $0.previous == nil || species($0.previous!)?.chain != me.chain }]
        while true {
            let ids = Set(stages.last!.map(\.dex))
            let next = members.filter { $0.previous.map(ids.contains) ?? false }
            if next.isEmpty { break }
            stages.append(next)
        }
        return stages
    }

    /// The version ids that match a game file's name ("Pokemon - Version Noire 2 (France)" → Noir 2).
    func versions(matching gameName: String) -> [Int] {
        let words = Self.words(gameName)
        let hasNumber = words.contains { $0.allSatisfy(\.isNumber) }
        return versions.filter { version in
            let wanted = Self.words(version.name)
            let numbered = wanted.contains { $0.allSatisfy(\.isNumber) }
            if hasNumber != numbered { return false }
            return wanted.allSatisfy { word in words.contains { $0.hasPrefix(word) } }
        }.map(\.id)
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0 != "pokemon" && $0 != "version" }
    }
}
