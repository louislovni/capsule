import SwiftUI

/// What the bank holds, across all games.
struct BankView: View {
    @ObservedObject var bank: BankStore
    @State private var trading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(bank.entries.count == 1 ? "1 Pokémon" : "\(bank.entries.count) Pokémon")
                    .smallCaps(.capsuleCream, opacity: 0.55)
                if bank.entries.isEmpty {
                    Text("La banque est vide. Touche l'icône de boîte sur la carte d'un jeu pour y déposer des Pokémon.")
                        .foregroundStyle(Color.capsuleCream.opacity(0.7))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(bank.entries) { entry in
                            NavigationLink {
                                MonDetailLoader(load: { entry.resolvedDetails() }, bankDate: entry.depositedAt)
                                    .capsuleScreen()
                            } label: {
                                BankCard(entry: entry)
                            }
                            .buttonStyle(SquishStyle())
                        }
                    }
                    Text("La banque est un fichier dans Capsule > Bank. Exporte-le pour le garder ailleurs ; importe-le depuis l'accueil pour fusionner.")
                        .font(.footnote)
                        .foregroundStyle(Color.capsuleCream.opacity(0.4))
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 30)
        }
        .background(Color.capsuleBlack.ignoresSafeArea())
        .navigationTitle("Banque")
        .sheet(isPresented: $trading) {
            TradeView(bank: bank)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    trading = true
                } label: {
                    Label("Échanger", systemImage: "arrow.left.arrow.right")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if !bank.entries.isEmpty {
                    ShareLink(item: bank.fileURL) {
                        Label("Exporter", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

/// A banked Pokémon on a card in its types' colours.
private struct BankCard: View {
    let entry: BankEntry

    var body: some View {
        let dex = TradeEvolution.nationalDex(of: entry)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Group {
                    if let dex = dex, !entry.isEgg {
                        PokedexSprite(dex: dex, shiny: entry.isShiny)
                    } else {
                        Image(systemName: "oval.portrait").font(.system(size: 30)).foregroundStyle(Color.capsuleInk.opacity(0.4))
                    }
                }
                .frame(width: 64, height: 64)
                .background(Circle().fill(.white.opacity(0.35)))
                Spacer()
                if entry.isShiny {
                    Image(systemName: "sparkles").foregroundStyle(Color(red: 0.75, green: 0.5, blue: 0)).accessibilityLabel("Chromatique")
                }
            }
            Text(entry.displayName)
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(Color(red: 0.063, green: 0.06, blue: 0.05))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 4)
            Text(PokedexStore.gameTitle(entry.sourceGame))
                .smallCaps(opacity: 0.65)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: Self.stops(dex), startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    /// Its types' pastel colours, as the Pokédex draws them.
    static func stops(_ dex: Int?) -> [Color] {
        guard let dex = dex, let base = PokedexStore.base(dex) else { return CardColors.stops(.standard) }
        func pastel(_ type: UInt8, _ light: CGFloat) -> Color {
            Color(UIColor(PokedexView.typeColors[Int(type) % 17]).mixed(with: .white, light))
        }
        return [pastel(base.type1, 0.55), pastel(base.type1, 0.7), pastel(base.type2, 0.6)]
    }
}

struct BankEntryRow: View {
    let entry: BankEntry

    var body: some View {
        HStack(spacing: 10) {
            if let dex = TradeEvolution.nationalDex(of: entry), !entry.isEgg {
                PokedexSprite(dex: dex, shiny: entry.isShiny).frame(width: 44, height: 44)
            }
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.displayName)
                    .font(.body.weight(.medium))
                if entry.isShiny {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Chromatique")
                }
            }
            Text("DO \(entry.trainerName) · \(entry.sourceGame) · \(entry.depositedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Moves Pokémon between one game's PC boxes and the bank.
///
/// Order of operations is chosen so that a failure can duplicate a Pokémon but
/// never lose one: a deposit is written to the bank before it leaves the save,
/// and a withdrawal reaches the save before it leaves the bank.
struct TransferView: View {
    let game: Game
    @ObservedObject var bank: BankStore
    @Environment(\.dismiss) private var dismiss

    private enum Side: String, CaseIterable, Identifiable {
        case pc = "PC du jeu"
        case bank = "Banque"
        var id: String { rawValue }
    }

    @State private var side: Side = .pc
    @State private var storage: PCStorage?
    @State private var shownDetails: MonDetails?
    @State private var shownBankDate: Date?
    @State private var boxes: [[BoxedMon]] = []
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Lecture de la sauvegarde…")
            } else if let loadError = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(loadError)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            } else {
                content.capsuleScreen()
            }
        }
        .background(Color.capsuleBlack.ignoresSafeArea())
        .navigationTitle(PokedexStore.gameTitle(game.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fermer") {
                    dismiss()
                }
            }
        }
        .alert("Transfert impossible", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                actionError = nil
            }
        } message: {
            Text(actionError ?? "")
        }
        .task {
            await load()
        }
        .navigationDestination(isPresented: detailsShown) {
            if let details = shownDetails {
                MonDetailView(details: details, bankDate: shownBankDate)
            }
        }
    }

    private var detailsShown: Binding<Bool> {
        Binding(get: { shownDetails != nil }, set: { if !$0 { shownDetails = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    private var generation: Int { storage?.generation ?? 3 }

    /// A boxed Pokémon's National Pokédex number, for its sprite (a GBA game numbers Hoenn its own way).
    private func nationalDex(_ mon: BoxedMon) -> Int? {
        guard !mon.isEgg else { return nil }
        if generation == 3 {
            return (storage as? SaveFile)?.rom?.nationalDex(species: mon.species) ?? (mon.species <= 251 ? mon.species : nil)
        }
        return mon.species
    }

    private var compatibleEntries: [BankEntry] {
        bank.entries.filter { $0.effectiveGeneration == generation }
    }

    @ViewBuilder
    private var content: some View {
        List {
            Section {
                Picker("Côté", selection: $side) {
                    ForEach(Side.allCases) { side in
                        Text(side.rawValue).tag(side)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                if let storage = storage {
                    Text("\(storage.gameFamily) · \(storage.summaryLine)")
                }
            }

            switch side {
            case .pc:
                pcSections
            case .bank:
                bankSection
            }
        }
    }

    @ViewBuilder
    private var pcSections: some View {
        if boxes.allSatisfy({ $0.isEmpty }) {
            Text("Le PC de cette partie est vide. Seuls les Pokémon rangés dans les boîtes peuvent être déposés, pas ceux de l'équipe.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(boxes.indices, id: \.self) { box in
                if !boxes[box].isEmpty {
                    Section(storage?.boxName(box) ?? "Boîte \(box + 1)") {
                        ForEach(boxes[box]) { mon in
                            HStack {
                                Button {
                                    shownBankDate = nil
                                    shownDetails = storage?.details(of: mon)
                                } label: {
                                    HStack(spacing: 10) {
                                        if let dex = nationalDex(mon) {
                                            PokedexSprite(dex: dex, shiny: mon.isShiny).frame(width: 44, height: 44)
                                        }
                                        MonLabel(name: mon.displayName, trainer: mon.trainer, isShiny: mon.isShiny)
                                        Spacer()
                                        Image(systemName: "info.circle")
                                            .foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button("Déposer") {
                                    deposit(mon)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
        if let note = storage?.footnote {
            Section {
                EmptyView()
            } footer: {
                Text(note)
            }
        }
    }

    @ViewBuilder
    private var bankSection: some View {
        let entries = compatibleEntries
        if entries.isEmpty {
            Text(bank.entries.isEmpty ? "La banque est vide." : "Aucun Pokémon de cette génération dans la banque.")
                .foregroundStyle(.secondary)
        } else {
            Section {
                ForEach(entries) { entry in
                    HStack {
                        Button {
                            shownBankDate = entry.depositedAt
                            shownDetails = entry.resolvedDetails()
                        } label: {
                            HStack {
                                BankEntryRow(entry: entry)
                                Spacer()
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button("Retirer") {
                            withdraw(entry)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } footer: {
                Text("Un Pokémon retiré va dans la première place libre du PC. Relance ensuite le jeu depuis sa sauvegarde, pas depuis un état enregistré avant le transfert.")
            }
        }
        let others = bank.entries.count - entries.count
        if others > 0 {
            Section {
                EmptyView()
            } footer: {
                Text(others == 1
                    ? "1 Pokémon d'une autre génération reste dans la banque : il ne peut aller que dans un jeu de sa génération."
                    : "\(others) Pokémon d'autres générations restent dans la banque : chacun ne peut aller que dans un jeu de sa génération.")
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        let game = self.game
        let outcome = await Task.detached(priority: .userInitiated) { () -> (PCStorage?, String?) in
            guard FileManager.default.fileExists(atPath: game.saveURL.path) else {
                return (nil, "Pas encore de sauvegarde pour ce jeu. Lance-le et sauvegarde une fois depuis son menu.")
            }
            do {
                return (try Self.openStorage(for: game), nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        }.value
        storage = outcome.0
        loadError = outcome.1
        reloadBoxes()
        isLoading = false
    }

    nonisolated private static func openStorage(for game: Game) throws -> PCStorage {
        if game.isDS {
            return try NDSSaveFile(url: game.saveURL, sourceGame: game.name)
        }
        if game.romURL.pathExtension.lowercased() == "gba" {
            let save = try SaveFile(url: game.saveURL)
            save.rom = RomData.load(game.romURL)
            return save
        }
        return try GBSaveFile(url: game.saveURL, sourceGame: game.name)
    }

    private func reloadBoxes() {
        guard let storage = storage else {
            boxes = []
            return
        }
        boxes = (0..<storage.boxCount).map { storage.listMons(inBox: $0) }
    }

    private func deposit(_ mon: BoxedMon) {
        guard let storage = storage else { return }
        let details = storage.details(of: mon)
        let entry = BankEntry(
            id: UUID(),
            data: mon.raw,
            species: mon.species,
            speciesName: mon.speciesName,
            nickname: mon.nickname,
            trainerName: mon.trainer,
            isShiny: mon.isShiny,
            isEgg: mon.isEgg,
            sourceGame: game.name,
            depositedAt: Date(),
            details: details,
            generation: storage.generation == 3 ? nil : storage.generation
        )
        do {
            try bank.add(entry)
        } catch {
            actionError = "La banque n'a pas pu être enregistrée : \(error.localizedDescription)"
            return
        }
        do {
            try storage.remove(mon)
            try storage.write()
            game.markBankTransfer()
        } catch {
            // The save was not updated: take the Pokémon back out of the bank.
            try? bank.remove(entry)
            actionError = error.localizedDescription
            reopen()
        }
        reloadBoxes()
    }

    private func withdraw(_ entry: BankEntry) {
        guard let storage = storage else { return }
        do {
            _ = try storage.deposit(entry.data)
            try storage.write()
            game.markBankTransfer()
        } catch {
            actionError = error.localizedDescription
            reopen()
            reloadBoxes()
            return
        }
        do {
            try bank.remove(entry)
        } catch {
            actionError = "Le Pokémon est arrivé dans le jeu, mais la banque n'a pas pu être mise à jour : il y figure encore."
        }
        reloadBoxes()
    }

    /// After a failed write, memory and disk may disagree: start again from disk.
    private func reopen() {
        storage = try? Self.openStorage(for: game)
    }
}

private struct MonLabel: View {
    let name: String
    let trainer: String
    let isShiny: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name)
                    .font(.body.weight(.medium))
                if isShiny {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Chromatique")
                }
            }
            Text("DO \(trainer)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
