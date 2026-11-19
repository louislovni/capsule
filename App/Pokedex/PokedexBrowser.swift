import SwiftUI

/// The Pokédex in Capsule's look: one Pokémon at a time on a card in its types' colours, its
/// animated sprite floating, its name large, and its sections (sheet, stats, evolutions, where
/// to catch it) on the wheel in the notch. Arrows or a swipe go to the next one; the search and
/// the filter sit in the black under the card.
struct PokedexBrowser: View {
    @ObservedObject var pokedex: PokedexStore
    let games: [Game]
    let refresh: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var current = 1
    @State private var section = Section.sheet
    @State private var filter = PokedexView.Filter.all
    @State private var shiny = false
    @State private var search = ""
    @State private var showsGrid = false
    @State private var direction: CGFloat = 1
    @StateObject private var wheelTint = PictureTint()
    @FocusState private var searching: Bool

    enum Section: Int, CaseIterable {
        case sheet, stats, evolutions, places

        var title: String { ["Fiche", "Statistiques", "Évolutions", "Où l'attraper"][rawValue] }
        var short: String { ["FICHE", "STATS", "ÉVOL.", "LIEUX"][rawValue] }
        var icon: String { ["text.book.closed", "chart.bar", "arrow.triangle.branch", "map"][rawValue] }
    }

    private let ink = Color(red: 0.114, green: 0.09, blue: 0.07)

    private var record: PokedexStore.Record? { pokedex.record(current) }
    private var owned: Bool { record?.owned == true }
    private var known: Bool { record != nil }
    private var info: PokedexInfo.Species? { PokedexInfo.shared.species(current) }

    /// The Pokémon the arrows step through: the whole Pokédex, or those the filter keeps.
    private var order: [Int] {
        (1...PokedexStore.maxDex).filter { dex in
            let record = pokedex.record(dex)
            switch filter {
            case .all: return true
            case .caught: return record?.owned == true
            case .missing: return record?.owned != true
            case .shiny: return record?.shiny == true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            card
                .padding(.horizontal, 5)
                .padding(.top, 5)
            bottomBar
        }
        .background(Color(red: 0.043, green: 0.039, blue: 0.035).ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) { searchResults }
        .sheet(isPresented: $showsGrid) {
            NavigationStack {
                PokedexView(pokedex: pokedex, games: games, refresh: refresh, onPick: { dex in
                    go(to: dex)
                    showsGrid = false
                })
            }
        }
        .task { await refresh() }
        .onAppear { updateTint() }
        .onChange(of: current) { _ in updateTint() }
        .onChange(of: shiny) { _ in updateTint() }
        .preferredColorScheme(.dark)
    }

    // MARK: The card

    private var card: some View {
        GeometryReader { geometry in
            let top = geometry.safeAreaInsets.top
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: cardStops, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .animation(.easeInOut(duration: 0.6), value: current)
                    .animation(.easeInOut(duration: 0.6), value: shiny)
                RadialGradient(colors: [.white.opacity(0.38), .white.opacity(0)],
                               center: UnitPoint(x: 0.85, y: 0.18), startRadius: 0, endRadius: 320)
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                        .padding(.top, max(top, 50) + 6)
                        .padding(.horizontal, 16)
                    facts
                        .padding(.top, 18)
                        .padding(.horizontal, 22)
                    HStack(alignment: .center, spacing: 0) {
                        sprite
                        Spacer(minLength: 0)
                        CapsuleWheel(tint: wheelTint, tools: Section.allCases.map { item in
                            WheelTool(id: item.title, short: item.short, icon: item.icon) {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { section = item }
                            }
                        }, opensOnRoll: true)
                    }
                    .padding(.leading, 22)
                    .padding(.top, 6)
                    name
                        .padding(.horizontal, 22)
                    sectionContent
                        .padding(.top, 12)
                    footer
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let dx = value.translation.width, dy = value.translation.height
                        guard abs(dx) > 70, abs(dx) > abs(dy) * 1.6 else { return }
                        step(dx < 0 ? 1 : -1)
                    }
            )
        }
    }

    /// Pastel stops from the Pokémon's types (grey while not met); shinies lean another way.
    private var cardStops: [Color] {
        guard known, let base = PokedexStore.base(current) else {
            return [Color(white: 0.82), Color(white: 0.9), Color(white: 0.78), Color(white: 0.86)]
        }
        func pastel(_ type: UInt8, _ light: CGFloat, _ shift: CGFloat = 0) -> Color {
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            UIColor(PokedexView.typeColors[Int(type) % 17]).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            var hue = h + shift + (shiny ? 0.12 : 0)
            if hue > 1 { hue -= 1 }
            if hue < 0 { hue += 1 }
            return Color(UIColor(hue: hue, saturation: min(s, 0.6), brightness: 0.85, alpha: 1).mixed(with: .white, light))
        }
        return [pastel(base.type1, 0.42), pastel(base.type1, 0.6, 0.03), pastel(base.type2, 0.45), pastel(base.type1, 0.52, -0.03)]
    }

    private func updateTint() {
        guard known, let base = PokedexStore.base(current) else {
            wheelTint.value = Tint(r: 0.5, g: 0.5, b: 0.5)
            return
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(PokedexView.typeColors[Int(base.type1) % 17]).getRed(&r, green: &g, blue: &b, alpha: &a)
        withAnimation(.easeInOut(duration: 0.5)) {
            wheelTint.value = Tint(r: r, g: g, b: b)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            glassButton("chevron.left", label: "Retour") { dismiss() }
            glassButton("square.grid.3x3", label: "Tous les Pokémon") { showsGrid = true }
            Spacer()
            if owned {
                glassButton(shiny ? "sparkles" : "sparkle", label: shiny ? "Couleurs normales" : "Couleurs chromatiques",
                            lit: shiny) { shiny.toggle() }
            }
            Menu {
                ForEach(PokedexStore.regions, id: \.name) { region in
                    Button(region.name) {
                        if let first = order.first(where: { region.range.contains($0) }) {
                            go(to: first)
                        }
                    }
                }
            } label: {
                Text(PokedexStore.regions.first { $0.range.contains(current) }?.name ?? "Région")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 20)
                    .frame(height: 46)
                    .background(glassFill, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.6), lineWidth: 1))
                    .shadow(color: Color(red: 0.24, green: 0.12, blue: 0.04).opacity(0.14), radius: 9, y: 8)
            }
        }
    }

    private var glassFill: RadialGradient {
        RadialGradient(colors: [.white.opacity(0.78), .white.opacity(0.3)], center: UnitPoint(x: 0.3, y: 0.2),
                       startRadius: 0, endRadius: 60)
    }

    private func glassButton(_ icon: String, label: String, lit: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(lit ? Color(red: 0.75, green: 0.45, blue: 0.0) : ink)
                .frame(width: 46, height: 46)
                .background(lit ? RadialGradient(colors: [Color(red: 1, green: 0.95, blue: 0.7), Color(red: 1, green: 0.82, blue: 0.4)],
                                                 center: UnitPoint(x: 0.3, y: 0.2), startRadius: 0, endRadius: 50) : glassFill,
                            in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                .shadow(color: Color(red: 0.24, green: 0.12, blue: 0.04).opacity(0.14), radius: 9, y: 8)
        }
        .buttonStyle(SquishStyle())
        .accessibilityLabel(label)
    }

    private var facts: some View {
        let base = PokedexStore.base(current)
        let types = base.map { $0.type1 == $0.type2 ? [$0.type1] : [$0.type1, $0.type2] } ?? []
        let lines = [
            "N° \(String(format: "%03d", current))" + (known ? (info.map { " · \($0.category)" } ?? "") : ""),
            known ? "Type : " + types.map(PokedexStore.typeName).joined(separator: " · ") : "Type : ?",
            known ? (info.map { "Taille : \($0.heightText) · Poids : \($0.weightText)" } ?? "") : "Taille : ? · Poids : ?",
            "Statut : " + status,
        ].filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(lines, id: \.self) { line in
                Text(line)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .tracking(1.6)
        .textCase(.uppercase)
        .foregroundStyle(ink.opacity(0.78))
        .id(current)
        .transition(.opacity)
    }

    private var status: String {
        guard let record = record else { return "pas encore rencontré" }
        if !record.owned { return "vu" }
        var places: [String] = []
        if record.bank > 0 { places.append("banque") }
        if !record.games.isEmpty { places.append(record.games.count > 1 ? "\(record.games.count) jeux" : "1 jeu") }
        return "obtenu" + (places.isEmpty ? "" : " · " + places.joined(separator: " · ")) + (record.shiny ? " · ★" : "")
    }

    @State private var floating = false

    private var sprite: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.55), .white.opacity(0.15)], center: UnitPoint(x: 0.4, y: 0.35),
                                     startRadius: 0, endRadius: 80))
            Group {
                if owned {
                    AnimatedSprite(dex: current, shiny: shiny)
                } else {
                    PokedexSprite(dex: current, known: known)
                        .opacity(known ? 0.55 : 0.85)
                }
            }
            .frame(width: 118, height: 118)
            .id("\(current)-\(shiny)")
            .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity),
                                    removal: .opacity))
        }
        .frame(width: 140, height: 140)
        .offset(y: floating ? -6 : 0)
        .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: floating)
        .onAppear { floating = true }
    }

    private var name: some View {
        let text = known ? PokedexStore.name(current) : "???"
        return Text(text)
            .font(.system(size: 64, weight: .heavy))
            .tracking(-1.6)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .foregroundStyle(Color(red: 0.07, green: 0.06, blue: 0.05))
            .padding(.trailing, 40)
            .id(current)
            .transition(.asymmetric(insertion: .offset(x: 30 * direction).combined(with: .opacity), removal: .opacity))
    }

    // MARK: Sections

    private var sectionContent: some View {
        ScrollView(showsIndicators: false) {
            Group {
                switch section {
                case .sheet: sheet
                case .stats: stats
                case .evolutions: evolutions
                case .places: places
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id("\(current)-\(section.rawValue)")
            .transition(.asymmetric(insertion: .offset(y: 14).combined(with: .opacity), removal: .opacity))
        }
        .frame(maxHeight: .infinity)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9),
                                     .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(ink.opacity(0.7))
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.white.opacity(0.45), in: Capsule())
    }

    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            if known, let info = info, !info.abilities.isEmpty {
                label("Talents")
                FlowRow(spacing: 8) {
                    ForEach(info.abilities, id: \.name) { ability in
                        chip {
                            HStack(spacing: 4) {
                                Text(ability.name).font(.system(size: 14, weight: .medium))
                                if ability.hidden {
                                    Text("caché").font(.system(size: 12)).foregroundStyle(ink.opacity(0.6))
                                }
                            }
                        }
                    }
                }
            }
            label("Où tu l'as").padding(.top, 6)
            Text(whereYouHaveIt)
                .font(.system(size: 15))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var whereYouHaveIt: String {
        guard let record = record else { return "Pas encore rencontré." }
        guard record.owned else {
            return "Vu dans " + record.dexSeen.sorted().map(PokedexStore.gameTitle).joined(separator: ", ") + ", pas encore attrapé."
        }
        var parts: [String] = []
        if record.bank > 0 { parts.append("Banque × \(record.bank)") }
        for game in record.games.keys.sorted() {
            parts.append("\(PokedexStore.gameTitle(game)) × \(record.games[game] ?? 0)" + (record.team.contains(game) ? " (équipe)" : ""))
        }
        for game in record.dexCaught.subtracting(record.games.keys).sorted() {
            parts.append("attrapé dans \(PokedexStore.gameTitle(game))")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var stats: some View {
        if known, let base = PokedexStore.base(current) {
            let values = [base.stats.0, base.stats.1, base.stats.2, base.stats.3, base.stats.4, base.stats.5].map(Int.init)
            let names = ["PV", "Attaque", "Défense", "Vitesse", "Atq. Spé.", "Déf. Spé."]
            VStack(alignment: .leading, spacing: 9) {
                ForEach([0, 1, 2, 4, 5, 3], id: \.self) { index in
                    HStack(spacing: 8) {
                        Text(names[index])
                            .font(.system(size: 11, weight: .medium)).tracking(1.2).textCase(.uppercase)
                            .foregroundStyle(ink.opacity(0.72))
                            .frame(width: 78, alignment: .leading)
                        Text("\(values[index])")
                            .font(.system(size: 14, weight: .bold)).monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                        GeometryReader { geometry in
                            Capsule().fill(ink.opacity(0.12))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(ink.opacity(0.75))
                                        .frame(width: geometry.size.width * min(1, CGFloat(values[index]) / 180))
                                }
                        }
                        .frame(height: 10)
                    }
                }
                label("Total \(values.reduce(0, +))").padding(.top, 2)
            }
        } else {
            Text("Rencontre-le pour voir ses statistiques.").foregroundStyle(ink.opacity(0.7))
        }
    }

    @ViewBuilder private var evolutions: some View {
        let stages = PokedexInfo.shared.family(of: current).flatMap { $0 }
        if stages.count > 1 {
            VStack(spacing: 6) {
                ForEach(stages, id: \.dex) { member in
                    let memberRecord = pokedex.record(member.dex)
                    Button {
                        go(to: member.dex)
                    } label: {
                        HStack(spacing: 12) {
                            PokedexSprite(dex: member.dex, known: memberRecord != nil)
                                .opacity(memberRecord?.owned == true || memberRecord == nil ? 1 : 0.55)
                                .frame(width: 40, height: 40)
                                .background(ink.opacity(0.08), in: Circle())
                            Text(memberRecord != nil ? PokedexStore.name(member.dex) : "???")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(ink)
                            Spacer()
                            if let how = member.how {
                                Text(how).font(.system(size: 12)).foregroundStyle(ink.opacity(0.66))
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.leading, 6)
                        .padding(.trailing, 16)
                        .background(.white.opacity(member.dex == current ? 0.7 : 0.4), in: Capsule())
                    }
                    .buttonStyle(SquishStyle())
                }
            }
        } else {
            Text("N'évolue pas.").foregroundStyle(ink.opacity(0.7))
        }
    }

    @ViewBuilder private var places: some View {
        if let info = info, !info.places.isEmpty {
            let mine = Set(games.flatMap { PokedexInfo.shared.versions(matching: $0.name) })
            let ordered = PokedexInfo.shared.versions.map(\.id).filter { info.places[$0] != nil }
            let sorted = ordered.filter(mine.contains) + ordered.filter { !mine.contains($0) }
            VStack(spacing: 6) {
                ForEach(sorted, id: \.self) { version in
                    let game = PokedexInfo.shared.versions.first { $0.id == version }?.name ?? "?"
                    ForEach(info.places[version] ?? []) { place in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                (Text(game).fontWeight(.semibold) + Text(" · \(place.location)"))
                                    .font(.system(size: 14))
                                Text(place.method).font(.system(size: 12)).foregroundStyle(ink.opacity(0.66))
                            }
                            Spacer()
                            Text(place.levels).font(.system(size: 12).monospacedDigit()).foregroundStyle(ink.opacity(0.66))
                        }
                        .foregroundStyle(ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.white.opacity(mine.contains(version) ? 0.6 : 0.38),
                                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                }
            }
        } else {
            Text("Pas dans la nature : évolution, œuf, échange ou événement.").foregroundStyle(ink.opacity(0.7))
        }
    }

    // MARK: Footer and bottom bar

    private var footer: some View {
        HStack(alignment: .bottom) {
            Text("\(pokedex.caught) / \(PokedexStore.maxDex)\nespèces obtenues")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.6)
                .textCase(.uppercase)
                .lineSpacing(2)
                .foregroundStyle(ink.opacity(0.72))
                .padding(.leading, 8)
            Spacer()
            HStack(spacing: 6) {
                arrow("chevron.up", label: "Pokémon précédent") { step(-1) }
                arrow("chevron.down", label: "Pokémon suivant") { step(1) }
            }
            .padding(5)
            .background(.white.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(ink.opacity(0.16), lineWidth: 1))
        }
    }

    private func arrow(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color(red: 0.91, green: 0.34, blue: 0.11))
                .frame(width: 58, height: 58)
                .background(RadialGradient(colors: [Color(red: 1, green: 0.98, blue: 0.92), Color(red: 0.92, green: 0.85, blue: 0.69)],
                                           center: UnitPoint(x: 0.4, y: 0.3), startRadius: 0, endRadius: 50), in: Circle())
                .shadow(color: Color(red: 0.24, green: 0.12, blue: 0.04).opacity(0.15), radius: 5, y: 4)
        }
        .buttonStyle(SquishStyle())
        .accessibilityLabel(label)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color(white: 0.78))
                TextField("Nom ou numéro", text: $search)
                    .focused($searching)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { if let first = matches.first { pick(first) } }
                    .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.91))
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color(white: 0.6))
                    }
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
            .background(Color(red: 0.12, green: 0.11, blue: 0.1), in: Capsule())
            Menu {
                Picker("Afficher", selection: $filter) {
                    ForEach(PokedexView.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(filter.rawValue)
                    Image(systemName: "chevron.up").font(.system(size: 12, weight: .bold))
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.91))
                .padding(.horizontal, 20)
                .frame(height: 54)
                .background(Color(red: 0.12, green: 0.11, blue: 0.1), in: Capsule())
            }
            .onChange(of: filter) { _ in
                let list = order
                if !list.contains(current), let next = list.first(where: { $0 > current }) ?? list.last {
                    go(to: next)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: Search

    private var matches: [Int] {
        let query = search.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !query.isEmpty else { return [] }
        let number = Int(query.trimmingCharacters(in: CharacterSet(charactersIn: "#0")))
        return (1...PokedexStore.maxDex).filter { dex in
            if dex == number { return true }
            guard pokedex.record(dex) != nil else { return false }
            return PokedexStore.name(dex).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(query)
        }
        .prefix(30).map { $0 }
    }

    @ViewBuilder private var searchResults: some View {
        if searching && !matches.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(matches, id: \.self) { dex in
                        Button { pick(dex) } label: {
                            HStack(spacing: 12) {
                                PokedexSprite(dex: dex, known: pokedex.record(dex) != nil).frame(width: 36, height: 36)
                                Text(String(format: "%03d", dex)).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                                Text(pokedex.record(dex) != nil ? PokedexStore.name(dex) : "???").font(.system(size: 16, weight: .semibold))
                                Spacer()
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 320)
            .background(Color(red: 0.12, green: 0.11, blue: 0.1), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.bottom, 84)
            .transition(.opacity.combined(with: .offset(y: 20)))
        }
    }

    private func pick(_ dex: Int) {
        searching = false
        search = ""
        go(to: dex)
    }

    // MARK: Moving

    private func step(_ by: Int) {
        let list = order
        guard !list.isEmpty else { return }
        let next: Int?
        if by > 0 {
            next = list.first { $0 > current } ?? list.first
        } else {
            next = list.last { $0 < current } ?? list.last
        }
        if let next = next {
            UISelectionFeedbackGenerator().selectionChanged()
            go(to: next, direction: CGFloat(by))
        }
    }

    private func go(to dex: Int, direction: CGFloat? = nil) {
        self.direction = direction ?? (dex >= current ? 1 : -1)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            current = dex
            shiny = pokedex.record(dex)?.owned == true && pokedex.record(dex)?.shiny == true
        }
    }
}

/// Lays its children in rows, wrapping to the next row when one is full.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
