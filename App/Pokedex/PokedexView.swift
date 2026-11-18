import ImageIO
import SwiftUI

/// The National Pokédex: what the bank and the games' boxes hold, with the Black/White sprites.
struct PokedexView: View {
    @ObservedObject var pokedex: PokedexStore
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
            case .caught: if record == nil { return false }
            case .missing: if record != nil { return false }
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
                            Text("\(region.range.filter { pokedex.record($0) != nil }.count) / \(region.range.count)")
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
            PokedexDetail(dex: item.id, record: pokedex.record(item.id))
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
                Text("Les espèces de ta banque et des boîtes de tes jeux.")
                    .font(.subheadline).foregroundStyle(.secondary)
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
        VStack(spacing: 2) {
            PokedexSprite(dex: dex, shiny: record?.shiny ?? false, known: record != nil)
                .frame(width: 64, height: 64)
            Text(record != nil ? PokedexStore.name(dex) : "???")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(record != nil ? .primary : .secondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
            Text(String(format: "%03d", dex)).font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary).padding(5)
        }
        .overlay(alignment: .topTrailing) {
            if record?.shiny == true {
                Text("★").font(.caption).foregroundStyle(.yellow).padding(4)
            } else if let record = record, record.bank == 0 {
                Image(systemName: "gamecontroller.fill").font(.system(size: 9)).foregroundStyle(.secondary).padding(5)
            }
        }
    }
}

private struct PokedexDetail: View {
    let dex: Int
    let record: PokedexStore.Record?
    @State private var shiny = false

    private static let statOrder = [0, 1, 2, 4, 5, 3]
    private static let statNames = ["PV", "Attaque", "Défense", "Vitesse", "Atq. Spé.", "Déf. Spé."]

    var body: some View {
        let base = PokedexStore.base(dex)
        ScrollView {
            VStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if record != nil {
                            AnimatedSprite(dex: dex, shiny: shiny)
                        } else {
                            PokedexSprite(dex: dex, known: false)
                        }
                    }
                    .frame(width: 160, height: 160)
                    .frame(maxWidth: .infinity)
                    if record != nil {
                        Button(shiny ? "★ Chromatique" : "☆ Normal") { shiny.toggle() }
                            .buttonStyle(.bordered)
                            .font(.footnote)
                    }
                }
                Text(String(format: "#%03d", dex)).foregroundStyle(.secondary)
                Text(PokedexStore.name(dex)).font(.largeTitle.bold())
                if let base = base {
                    HStack {
                        ForEach(base.type1 == base.type2 ? [base.type1] : [base.type1, base.type2], id: \.self) { type in
                            Text(PokedexStore.typeName(type))
                                .font(.subheadline.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(PokedexView.typeColors[Int(type) % 17], in: Capsule())
                        }
                    }
                    let stats = [base.stats.0, base.stats.1, base.stats.2, base.stats.3, base.stats.4, base.stats.5].map(Int.init)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Statistiques de base · \(stats.reduce(0, +))").font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary).textCase(.uppercase)
                        ForEach(Self.statOrder, id: \.self) { index in
                            HStack {
                                Text(Self.statNames[index]).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                                Text("\(stats[index])").monospacedDigit().frame(width: 34, alignment: .trailing)
                                GeometryReader { proxy in
                                    Capsule().fill(Color.secondary.opacity(0.2))
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(stats[index] >= 100 ? .green : stats[index] >= 70 ? .yellow : .orange)
                                                .frame(width: proxy.size.width * min(1, CGFloat(stats[index]) / 180))
                                        }
                                }
                                .frame(height: 7)
                            }
                            .font(.subheadline)
                        }
                    }
                    .padding(.top, 8)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Où tu l'as").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    if let record = record {
                        if record.bank > 0 {
                            Label("Banque · \(record.bank)", systemImage: "tray.full")
                        }
                        ForEach(record.games.keys.sorted(), id: \.self) { game in
                            Label("\(game) · \(record.games[game] ?? 0)", systemImage: "gamecontroller")
                        }
                    } else {
                        Text("Pas encore attrapé. Il apparaît ici dès qu'il est dans ta banque ou dans une boîte du PC d'un de tes jeux.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            .padding()
        }
        .onAppear { shiny = record?.shiny ?? false }
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
            let image = await Self.load(url) ?? Self.loadStill(PokedexStore.sprite(dex, shiny: shiny))
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
