import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @StateObject private var library = GameLibrary()
    @StateObject private var bank = BankStore()
    @StateObject private var account = AccountStore()
    @StateObject private var cloud = CloudSync()
    @StateObject private var pokedex = PokedexStore()
    @Environment(\.scenePhase) private var scenePhase

    @State private var importing = false
    @State private var playing: Game?
    @State private var transferGame: Game?
    @State private var pendingDelete: Game?
    @State private var pendingRestore: Game?
    @State private var restoreMessage: String?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if library.games.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Aucun jeu pour l'instant")
                                .font(.headline)
                            Text("Touche + pour importer tes ROM (.gba, .gb, .gbc, .nds) et tes sauvegardes .sav si tu en as. Tu peux aussi les déposer dans le dossier Capsule > ROMs de l'app Fichiers.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    } else {
                        ForEach(library.games) { game in
                            GameRow(game: game, play: { playing = game }, openBank: { transferGame = game })
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("Supprimer", role: .destructive) {
                                        pendingDelete = game
                                    }
                                    if SafetySave.date(for: game) != nil {
                                        Button("Secours") {
                                            pendingRestore = game
                                        }
                                        .tint(.orange)
                                    }
                                }
                        }
                    }
                } header: {
                    Text("Jeux")
                }

                Section {
                    NavigationLink {
                        PokedexView(pokedex: pokedex, games: library.games, refresh: refreshPokedex)
                    } label: {
                        Label("Pokédex · \(pokedex.caught) / \(PokedexStore.maxDex)", systemImage: "book.closed")
                    }
                    NavigationLink {
                        BankView(bank: bank)
                    } label: {
                        Label(bankSummary, systemImage: "tray.full")
                    }
                    NavigationLink {
                        AccountView(account: account, bank: bank, cloud: cloud)
                    } label: {
                        Label("Amis et échanges en ligne", systemImage: "person.2")
                    }
                    Link(destination: URL(string: "https://louislovni.github.io/capsule/")!) {
                        Label("Pokédex en ligne", systemImage: "globe")
                    }
                } header: {
                    Text("Banque")
                } footer: {
                    Text("Pour déposer ou retirer des Pokémon, touche l'icône de boîte à côté d'un jeu.")
                }

                Section {
                    NavigationLink {
                        PokeDaisySettingsView()
                    } label: {
                        Label("Réglages PokeDaisy", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        GamepadSettingsView()
                    } label: {
                        Label("Manette Bluetooth", systemImage: "gamecontroller")
                    }
                } footer: {
                    Text("Capsule \(Self.version)")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .navigationTitle("Capsule")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        importing = true
                    } label: {
                        Label("Importer", systemImage: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                handleImport(result)
            }
            .fullScreenCover(item: $playing, onDismiss: {
                library.refresh()
                Task {
                    await cloud.sync()
                    library.refresh()
                    await refreshPokedex()
                }
            }) { game in
                GameView(game: game)
            }
            .sheet(item: $transferGame) { game in
                NavigationStack {
                    TransferView(game: game, bank: bank)
                }
            }
            .confirmationDialog(
                "Revenir à la sauvegarde de secours ?",
                isPresented: restoreBinding,
                titleVisibility: .visible,
                presenting: pendingRestore
            ) { game in
                Button("Revenir à la copie de secours", role: .destructive) {
                    do {
                        try SafetySave.restore(game)
                        restoreMessage = "La sauvegarde de \(game.name) est revenue à sa copie de secours."
                    } catch {
                        restoreMessage = "La copie de secours n'a pas pu être remise : \(error.localizedDescription)"
                    }
                    pendingRestore = nil
                }
                Button("Annuler", role: .cancel) {
                    pendingRestore = nil
                }
            } message: { game in
                Text(SafetySave.date(for: game).map {
                    "La copie de secours est la sauvegarde du \($0.formatted(date: .long, time: .shortened)), gardée au dernier lancement du jeu. La sauvegarde actuelle sera conservée dans les copies datées."
                } ?? "")
            }
            .alert(restoreMessage ?? "", isPresented: Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .confirmationDialog(
                "Supprimer la ROM ?",
                isPresented: deleteBinding,
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { game in
                Button("Supprimer \(game.name)", role: .destructive) {
                    library.delete(game)
                    pendingDelete = nil
                }
                Button("Annuler", role: .cancel) {
                    pendingDelete = nil
                }
            } message: { _ in
                Text("Seul le fichier du jeu est supprimé. La sauvegarde et ses copies de secours sont conservées.")
            }
            .alert("Capsule", isPresented: messageBinding) {
                Button("OK", role: .cancel) {
                    message = nil
                    bank.lastError = nil
                }
            } message: {
                Text(message ?? bank.lastError ?? "")
            }
            .onAppear {
                library.refresh()
            }
            .task {
                cloud.attach(account: account, bank: bank)
                await account.restore()
                await cloud.sync()
                library.refresh()
                await refreshPokedex()
            }
            .onChange(of: scenePhase) { phase in
                // Leaving the app from the games list: what changed goes up. (In a game, its
                // own screen saves; the sync follows when it closes.)
                if phase == .background && playing == nil {
                    Task { await cloud.sync() }
                }
            }
        }
    }

    /// "0.1.36", the number AltStore shows too.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    private var bankSummary: String {
        switch bank.entries.count {
        case 0: return "La banque est vide"
        case 1: return "1 Pokémon en banque"
        default: return "\(bank.entries.count) Pokémon en banque"
        }
    }

    private var restoreBinding: Binding<Bool> {
        Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var messageBinding: Binding<Bool> {
        Binding(
            get: { message != nil || bank.lastError != nil },
            set: { shown in
                if !shown {
                    message = nil
                    bank.lastError = nil
                }
            }
        )
    }

    /// The Pokédex from the bank and the games' boxes, and its copy for the web page.
    private func refreshPokedex() async {
        await pokedex.refresh(bank: bank, games: library.games)
        await pokedex.upload(account: account)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            message = "Import impossible : \(error.localizedDescription)"
        case .success(let urls):
            let outcome = library.importFiles(urls)
            var lines: [String] = []
            if outcome.roms > 0 {
                lines.append(outcome.roms == 1 ? "1 jeu ajouté." : "\(outcome.roms) jeux ajoutés.")
            }
            if outcome.saves > 0 {
                lines.append(outcome.saves == 1 ? "1 sauvegarde ajoutée." : "\(outcome.saves) sauvegardes ajoutées.")
            }
            for file in outcome.bankFiles {
                do {
                    let added = try bank.merge(from: file)
                    lines.append(added == 0 ? "Banque : rien de nouveau dans le fichier." : "Banque : \(added) Pokémon ajoutés.")
                } catch {
                    lines.append("Banque : fichier illisible.")
                }
                try? FileManager.default.removeItem(at: file)
            }
            if !outcome.skipped.isEmpty {
                lines.append("Ignorés : " + outcome.skipped.joined(separator: ", ") + ".")
            }
            if !lines.isEmpty {
                message = lines.joined(separator: "\n")
            }
        }
    }
}

private struct GameRow: View {
    let game: Game
    let play: () -> Void
    let openBank: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(game.platformLabel + " · " + (game.hasSave ? "sauvegarde présente" : "pas encore de sauvegarde"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if game.supportsPokemonTools {
                Button(action: openBank) {
                    Label("Banque", systemImage: "archivebox")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .padding(8)
                }
                .buttonStyle(.borderless)
                .disabled(!game.hasSave)
            }
        }
    }
}
