import ImageIO
import SwiftUI

/// The National Pokédex: what the bank and the games' boxes hold, with the Black/White sprites.
struct PokedexView: View {
    @ObservedObject var pokedex: PokedexStore
    let games: [Game]
    let refresh: () async -> Void

    @State private var region = -1
    @State private var filter = Filter.all
    @State private var search = ""
    @State private var selected: Int?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Tous", caught = "Obtenus", missing = "Manquants", shiny = "Chromatiques"
        var id: String { rawValue }
    }

    static let typeColors: [Color] = [
        "9fa19f", "ff8000", "81b9ef", "9141cb", "915121", "afa981", "91a119", "704170", "60a1b8",
        "e62829", "2980ef", "3fa129", "fac000", "ef4179", "3dcef3", "5060e1", "624d4e",
    ].map { Color(hex: $0) }

    private var ranges: [(name: String, range: ClosedRange<Int>)] {
        region < 0 ? PokedexStore.regions : [PokedexStore.regions[region]]
    }

    private func visible(_ range: ClosedRange<Int>) -> [Int] {
        let query = search.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return range.filter { dex in
            let record = pokedex.record(dex)
            switch filter {
            case .all: break
            case .caught: if record?.owned != true { return false }
            case .missing: if record?.owned == true { return false }
            case .shiny: if record?.shiny != true { return false }
            }
            if query.isEmpty { return true }
            if String(dex) == query.trimmingCharacters(in: CharacterSet(charactersIn: "#0")) { return true }
            return PokedexStore.name(dex).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Picker("Région", selection: $region) {
                    Text("Tout").tag(-1)
                    ForEach(PokedexStore.regions.indices, id: \.self) { index in
                        Text(PokedexStore.regions[index].name).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Afficher", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                ForEach(ranges, id: \.name) { region in
                    let list = visible(region.range)
                    if !list.isEmpty {
                        HStack {
                            Text(region.name).font(.headline)
                            Spacer()
                            Text("\(region.range.filter { pokedex.record($0)?.owned == true }.count) / \(region.range.count)")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 6)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                            ForEach(list, id: \.self) { dex in
                                Button {
                                    selected = dex
                                } label: {
                                    PokedexCell(dex: dex, record: pokedex.record(dex))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Pokédex")
        .searchable(text: $search, prompt: "Nom ou numéro")
        .refreshable { await refresh() }
        .sheet(item: Binding(get: { selected.map(SelectedDex.init) }, set: { selected = $0?.id })) { item in
            PokedexDetail(dex: item.id, pokedex: pokedex, games: games)
                .presentationDetents([.medium, .large])
        }
        .task { await refresh() }
    }

    private var header: some View {
        let caught = pokedex.caught
        let shinies = pokedex.records.values.filter(\.shiny).count
        return HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: CGFloat(caught) / CGFloat(PokedexStore.maxDex))
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(caught)").font(.title2.bold())
                    Text("/ \(PokedexStore.maxDex)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 86, height: 86)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pokédex national").font(.headline)
                Text("Ta banque, les boîtes et l'équipe de tes jeux, et leur propre Pokédex.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if pokedex.seenOnly > 0 {
                    Text("\(pokedex.seenOnly) vu\(pokedex.seenOnly > 1 ? "s" : "") mais pas attrapé\(pokedex.seenOnly > 1 ? "s" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if shinies > 0 {
                    Text("★ \(shinies) chromatique\(shinies > 1 ? "s" : "")")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.yellow)
                }
                if pokedex.scanning {
                    Text("Lecture des sauvegardes…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SelectedDex: Identifiable {
    let id: Int
}

struct PokedexSprite: View {
    let dex: Int
    var shiny = false
    var known = true

    var body: some View {
        AsyncImage(url: PokedexStore.sprite(dex, shiny: shiny)) { phase in
            if let image = phase.image {
                image.interpolation(.none).resizable().scaledToFit()
                    .colorMultiply(known ? .white : .black)
                    .opacity(known ? 1 : 0.55)
            } else {
                Color.clear
            }
        }
    }
}

private struct PokedexCell: View {
    let dex: Int
    let record: PokedexStore.Record?

    var body: some View {
        let owned = record?.owned == true
        VStack(spacing: 2) {
            PokedexSprite(dex: dex, shiny: owned && record?.shiny == true, known: record != nil)
                .opacity(owned || record == nil ? 1 : 0.45)
                .frame(width: 64, height: 64)
            Text(record != nil ? PokedexStore.name(dex) : "???")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(owned ? .primary : .secondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
            Text(String(format: "%03d", dex)).font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary).padding(5)
        }
        .overlay(alignment: .topTrailing) {
            if record?.owned == true && record?.shiny == true {
                Text("★").font(.caption).foregroundStyle(.yellow).padding(4)
            } else if let record = record, !record.owned {
                Image(systemName: "eye").font(.system(size: 9)).foregroundStyle(.secondary).padding(5)
            } else if let record = record, record.bank == 0 {
                Image(systemName: "gamecontroller.fill").font(.system(size: 9)).foregroundStyle(.secondary).padding(5)
            }
        }
    }
}

private struct PokedexDetail: View {
    let dex: Int
    @ObservedObject var pokedex: PokedexStore
    let games: [Game]
    @State private var current: Int
    @State private var shiny = false
    @State private var openVersions: Set<Int>?

    init(dex: Int, pokedex: PokedexStore, games: [Game]) {
        self.dex = dex
        self.pokedex = pokedex
        self.games = games
        _current = State(initialValue: dex)
    }

    private static let statOrder = [0, 1, 2, 4, 5, 3]
    private static let statNames = ["PV", "Attaque", "Défense", "Vitesse", "Atq. Spé.", "Déf. Spé."]

    private var record: PokedexStore.Record? { pokedex.record(current) }
    private var owned: Bool { record?.owned == true }
    private var info: PokedexInfo.Species? { PokedexInfo.shared.species(current) }

    /// The player's games as version ids, first in "Où l'attraper".
    private var myVersions: [Int] {
        var seen = Set<Int>()
        return games.flatMap { PokedexInfo.shared.versions(matching: $0.name) }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    top.id("top")
                    stats
                    facts
                    evolutions(proxy)
                    whereYouHaveIt
                    whereToCatch
                }
                .padding()
            }
        }
        .onAppear { shiny = owned && record?.shiny == true }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
    }

    private var top: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if owned {
                        AnimatedSprite(dex: current, shiny: shiny)
                    } else {
                        PokedexSprite(dex: current, known: record != nil).opacity(record == nil ? 1 : 0.5)
                    }
                }
                .frame(width: 160, height: 160)
                .frame(maxWidth: .infinity)
                if owned {
                    Button(shiny ? "★ Chromatique" : "☆ Normal") { shiny.toggle() }
                        .buttonStyle(.bordered).font(.footnote)
                }
            }
            Text(String(format: "#%03d", current)).foregroundStyle(.secondary)
            Text(record != nil ? PokedexStore.name(current) : "???").font(.largeTitle.bold())
            if let info = info, !info.category.isEmpty {
                Text(info.category).foregroundStyle(.secondary)
            }
            if let base = PokedexStore.base(current) {
                HStack {
                    ForEach(base.type1 == base.type2 ? [base.type1] : [base.type1, base.type2], id: \.self) { type in
                        Text(PokedexStore.typeName(type))
                            .font(.subheadline.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(PokedexView.typeColors[Int(type) % 17], in: Capsule())
                    }
                }
            }
        }
    }

    @ViewBuilder private var stats: some View {
        if let base = PokedexStore.base(current) {
            let values = [base.stats.0, base.stats.1, base.stats.2, base.stats.3, base.stats.4, base.stats.5].map(Int.init)
            section("Statistiques de base · \(values.reduce(0, +))")
            ForEach(Self.statOrder, id: \.self) { index in
                HStack {
                    Text(Self.statNames[index]).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    Text("\(values[index])").monospacedDigit().frame(width: 34, alignment: .trailing)
                    GeometryReader { geometry in
                        Capsule().fill(Color.secondary.opacity(0.2))
                            .overlay(alignment: .leading) {
                                Capsule().fill(values[index] >= 100 ? .green : values[index] >= 70 ? .yellow : .orange)
                                    .frame(width: geometry.size.width * min(1, CGFloat(values[index]) / 180))
                            }
                    }
                    .frame(height: 7)
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder private var facts: some View {
        if let info = info {
            section("Fiche")
            HStack(spacing: 10) {
                fact("Taille", info.heightText)
                fact("Poids", info.weightText)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Talents").font(.caption).foregroundStyle(.secondary)
                ForEach(info.abilities, id: \.name) { ability in
                    HStack {
                        Text(ability.name)
                        if ability.hidden {
                            Text("caché").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func evolutions(_ proxy: ScrollViewProxy) -> some View {
        let stages = PokedexInfo.shared.family(of: current)
        if !stages.isEmpty {
            section("Évolutions")
            VStack(spacing: 6) {
                ForEach(stages.indices, id: \.self) { index in
                    if index > 0 {
                        Image(systemName: "arrow.down").font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(stages[index], id: \.dex) { member in
                                Button {
                                    current = member.dex
                                    shiny = pokedex.record(member.dex)?.owned == true && pokedex.record(member.dex)?.shiny == true
                                    withAnimation { proxy.scrollTo("top", anchor: .top) }
                                } label: {
                                    evolutionCard(member)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func evolutionCard(_ member: PokedexInfo.Species) -> some View {
        let memberRecord = pokedex.record(member.dex)
        return VStack(spacing: 2) {
            PokedexSprite(dex: member.dex, known: memberRecord != nil)
                .opacity(memberRecord?.owned == true || memberRecord == nil ? 1 : 0.5)
                .frame(width: 56, height: 56)
            Text(memberRecord != nil ? PokedexStore.name(member.dex) : "???").font(.caption.weight(.semibold))
            if let how = member.how {
                Text(how).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 118)
        .padding(.vertical, 8)
        .background(member.dex == current ? Color.red.opacity(0.18) : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var whereYouHaveIt: some View {
        section("Où tu l'as")
        VStack(alignment: .leading, spacing: 6) {
            if let record = record, record.owned {
                if record.bank > 0 {
                    Label("Banque · \(record.bank)", systemImage: "tray.full")
                }
                ForEach(record.games.keys.sorted(), id: \.self) { game in
                    Label("\(game) · \(record.games[game] ?? 0)\(record.team.contains(game) ? " (dans l'équipe)" : "")",
                          systemImage: "gamecontroller")
                }
                ForEach(record.dexCaught.subtracting(record.games.keys).sorted(), id: \.self) { game in
                    Label("Attrapé dans \(game) (plus dans ses boîtes)", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            } else if let record = record {
                Label("Vu dans \(record.dexSeen.sorted().joined(separator: ", ")), pas encore attrapé", systemImage: "eye")
                    .foregroundStyle(.secondary)
            } else {
                Text("Pas encore rencontré.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var whereToCatch: some View {
        if let info = info, !info.places.isEmpty {
            let mine = myVersions
            let order = PokedexInfo.shared.versions.map(\.id).filter { info.places[$0] != nil }
            let sorted = order.filter(mine.contains) + order.filter { !mine.contains($0) }
            section("Où l'attraper")
            VStack(spacing: 6) {
                ForEach(sorted, id: \.self) { version in
                    DisclosureGroup(isExpanded: Binding(
                        get: { (openVersions ?? Set(mine)).contains(version) },
                        set: { open in
                            var opened = openVersions ?? Set(mine)
                            if open { opened.insert(version) } else { opened.remove(version) }
                            openVersions = opened
                        })) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(info.places[version] ?? []) { place in
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(place.location)
                                        Text(place.method).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(place.levels).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        HStack {
                            Text(PokedexInfo.shared.versions.first { $0.id == version }?.name ?? "?").font(.headline)
                            if mine.contains(version) {
                                Text("ton jeu").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.red, in: Capsule())
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        } else if info != nil {
            section("Où l'attraper")
            Text("Pas dans la nature : évolution, œuf, échange ou événement.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension Color {
    init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// An animated Black/White sprite (GIF), drawn with sharp pixels. Falls back to the still one.
struct AnimatedSprite: UIViewRepresentable {
    let dex: Int
    var shiny = false

    private static let cache = NSCache<NSURL, UIImage>()

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.layer.magnificationFilter = .nearest
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        let url = PokedexStore.sprite(dex, shiny: shiny, animated: true)
        guard view.accessibilityIdentifier != url.absoluteString else { return }
        view.accessibilityIdentifier = url.absoluteString
        if let cached = Self.cache.object(forKey: url as NSURL) {
            view.image = cached
            return
        }
        view.image = nil
        Task {
            var image = await Self.load(url)
            if image == nil {
                image = await Self.loadStill(PokedexStore.sprite(dex, shiny: shiny))
            }
            guard view.accessibilityIdentifier == url.absoluteString, let image = image else { return }
            Self.cache.setObject(image, forKey: url as NSURL)
            view.image = image
        }
    }

    private static func load(_ url: URL) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        var frames: [UIImage] = []
        var total = 0.0
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            var delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            if delay < 0.02 { delay = 0.1 }
            // UIImage plays frames at an even pace: repeat each one for its own share of time.
            let repeats = max(1, Int((delay / 0.02).rounded()))
            let frame = UIImage(cgImage: cgImage)
            frames.append(contentsOf: Array(repeating: frame, count: repeats))
            total += delay
        }
        return frames.count > 1 ? UIImage.animatedImage(with: frames, duration: total) : frames.first
    }

    private static func loadStill(_ url: URL) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }
}
