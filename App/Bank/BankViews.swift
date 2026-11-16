import SwiftUI

/// What the bank holds, across all games.
struct BankView: View {
    @ObservedObject var bank: BankStore

    var body: some View {
        List {
            if bank.entries.isEmpty {
                Text("La banque est vide. Ouvre la boîte d'un jeu depuis la liste des jeux pour y déposer des Pokémon.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(bank.entries) { entry in
                        NavigationLink {
                            MonDetailLoader(load: { entry.resolvedDetails() }, bankDate: entry.depositedAt)
                        } label: {
                            BankEntryRow(entry: entry)
                        }
                    }
                } footer: {
                    Text("La banque est un fichier dans Capsule > Bank. Exporte-le pour le garder ailleurs ; importe-le depuis l'écran des jeux pour fusionner.")
                }
            }
        }
        .navigationTitle("Banque")
        .toolbar {
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

struct BankEntryRow: View {
    let entry: BankEntry

    var body: some View {
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
    @State private var save: SaveFile?
    @State private var rom: RomData?
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
                content
            }
        }
        .navigationTitle(game.name)
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
                if let save = save {
                    Text("\(save.gameFamily) · Dresseur \(save.trainerName) · \(save.playTime)")
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
                    Section(save?.boxName(box) ?? "Boîte \(box + 1)") {
                        ForEach(boxes[box]) { mon in
                            HStack {
                                Button {
                                    shownBankDate = nil
                                    shownDetails = MonDetails.make(raw: mon.raw, rom: rom)
                                } label: {
                                    HStack {
                                        MonLabel(name: displayName(mon.summary), trainer: mon.summary.trainerName, isShiny: mon.summary.isShiny)
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
    }

    @ViewBuilder
    private var bankSection: some View {
        if bank.entries.isEmpty {
            Text("La banque est vide.")
                .foregroundStyle(.secondary)
        } else {
            Section {
                ForEach(bank.entries) { entry in
                    HStack {
                        Button {
                            shownBankDate = entry.depositedAt
                            shownDetails = entry.details ?? MonDetails.make(raw: entry.data, rom: rom)
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
    }

    // MARK: - Actions

    private func displayName(_ summary: MonSummary) -> String {
        if summary.isEgg { return "Œuf" }
        let species = rom?.speciesName(summary.species) ?? "Pokémon n°\(summary.species)"
        if summary.nickname.isEmpty || summary.nickname.caseInsensitiveCompare(species) == .orderedSame {
            return species
        }
        return "\(summary.nickname) (\(species))"
    }

    private func load() async {
        let saveURL = game.saveURL
        let romURL = game.romURL
        let outcome = await Task.detached(priority: .userInitiated) { () -> (SaveFile?, RomData?, String?) in
            guard FileManager.default.fileExists(atPath: saveURL.path) else {
                return (nil, nil, "Pas encore de sauvegarde pour ce jeu. Lance-le et sauvegarde une fois depuis son menu.")
            }
            do {
                let save = try SaveFile(url: saveURL)
                return (save, RomData.load(romURL), nil)
            } catch {
                return (nil, nil, error.localizedDescription)
            }
        }.value
        save = outcome.0
        rom = outcome.1
        loadError = outcome.2
        reloadBoxes()
        isLoading = false
    }

    private func reloadBoxes() {
        guard let save = save else {
            boxes = []
            return
        }
        boxes = (0..<SaveFile.boxCount).map { save.mons(inBox: $0) }
    }

    private func deposit(_ mon: BoxedMon) {
        guard let save = save else { return }
        let summary = mon.summary
        let entry = BankEntry(
            id: UUID(),
            data: mon.raw,
            species: summary.species,
            speciesName: rom?.speciesName(summary.species) ?? "Pokémon n°\(summary.species)",
            nickname: summary.nickname,
            trainerName: summary.trainerName,
            isShiny: summary.isShiny,
            isEgg: summary.isEgg,
            sourceGame: game.name,
            depositedAt: Date(),
            details: MonDetails.make(raw: mon.raw, rom: rom)
        )
        do {
            try bank.add(entry)
        } catch {
            actionError = "La banque n'a pas pu être enregistrée : \(error.localizedDescription)"
            return
        }
        do {
            try save.remove(box: mon.box, slot: mon.slot)
            try save.write()
            game.markBankTransfer()
        } catch {
            // The save was not updated: take the Pokémon back out of the bank.
            try? bank.remove(entry)
            actionError = error.localizedDescription
            reopenSave()
        }
        reloadBoxes()
    }

    private func withdraw(_ entry: BankEntry) {
        guard let save = save else { return }
        do {
            _ = try save.deposit(entry.data)
            try save.write()
            game.markBankTransfer()
        } catch {
            actionError = error.localizedDescription
            reopenSave()
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
    private func reopenSave() {
        save = try? SaveFile(url: game.saveURL)
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
