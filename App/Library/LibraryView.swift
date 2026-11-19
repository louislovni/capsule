import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @StateObject private var library = GameLibrary()
    @StateObject private var bank = BankStore()
    @StateObject private var account = AccountStore()
    @StateObject private var cloud = CloudSync()
    @StateObject private var pokedex = PokedexStore()
    /// Held, not watched: only the cartridges redraw as the phone moves, not the whole screen.
    @State private var tilt = PhoneTilt()
    @Environment(\.scenePhase) private var scenePhase

    @State private var importing = false
    @State private var playing: Game?
    @State private var transferGame: Game?
    @State private var pendingDelete: Game?
    @State private var pendingRestore: Game?
    @State private var historyGame: Game?
    @State private var restoreMessage: String?
    @State private var message: String?
    @State private var path: [Route] = []

    enum Route: Hashable {
        case pokedex, bank, account, settings, gamepad
    }

    var body: some View {
        NavigationStack(path: $path) {
            home
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .pokedex:
                    PokedexBrowser(pokedex: pokedex, games: library.games, refresh: refreshPokedex)
                case .bank:
                    BankView(bank: bank)
                case .account:
                    AccountView(account: account, bank: bank, cloud: cloud)
                case .settings:
                    PokeDaisySettingsView().capsuleScreen()
                case .gamepad:
                    GamepadSettingsView().capsuleScreen()
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
            .sheet(item: $historyGame) { game in
                SaveHistoryView(game: game) { message in
                    historyGame = nil
                    restoreMessage = message
                } onSafety: {
                    historyGame = nil
                    pendingRestore = game
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

    // MARK: Home

    /// The games as cards in their colours, then the Pokédex, the bank and the trades as tiles.
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if library.games.isEmpty {
                    emptyCard
                }
                ForEach(library.games) { game in
                    GameCard(game: game, tilt: tilt,
                             play: {
                                 // No slide-up: the game's screen lights up where the cartridge went in (GameView).
                                 var instant = Transaction()
                                 instant.disablesAnimations = true
                                 withTransaction(instant) { playing = game }
                             },
                             openBank: { transferGame = game },
                             history: { historyGame = game },
                             delete: { pendingDelete = game })
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    NavigationLink(value: Route.pokedex) {
                        HomeTile(icon: "book.closed", title: "Pokédex",
                                 detail: "\(pokedex.caught) / \(PokedexStore.maxDex)",
                                 progress: Double(pokedex.caught) / Double(PokedexStore.maxDex))
                    }
                    NavigationLink(value: Route.bank) {
                        HomeTile(icon: "tray.full", title: "Banque", detail: bankSummary)
                    }
                    NavigationLink(value: Route.account) {
                        HomeTile(icon: "person.2", title: "Échanges", detail: "Amis et échanges en ligne")
                    }
                    Link(destination: URL(string: "https://louislovni.github.io/capsule/")!) {
                        HomeTile(icon: "globe", title: "Pokédex web", detail: "Sur ton ordinateur")
                    }
                }
                .buttonStyle(SquishStyle())
                .padding(.top, 6)
                HStack(spacing: 10) {
                    NavigationLink(value: Route.settings) {
                        pill("slider.horizontal.3", "Réglages PokeDaisy")
                    }
                    NavigationLink(value: Route.gamepad) {
                        pill("gamecontroller", "Manette")
                    }
                }
                .buttonStyle(SquishStyle())
                Text("Capsule \(Self.version)")
                    .smallCaps(.capsuleCream, opacity: 0.35)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 30)
        }
        .background(Color.capsuleBlack.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { tilt.start() }
        .onDisappear { tilt.stop() }
        .onChange(of: playing) { game in
            if game == nil { tilt.start() } else { tilt.stop() }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Capsule")
                    .font(.system(size: 44, weight: .heavy))
                    .tracking(-1.4)
                    .foregroundStyle(Color.capsuleCream)
                Text("\(library.games.count) jeu\(library.games.count > 1 ? "x" : "") · \(pokedex.caught) espèces obtenues")
                    .smallCaps(.capsuleCream, opacity: 0.55)
            }
            Spacer()
            Button {
                importing = true
            } label: {
                GlassCircle(icon: "plus", size: 48)
            }
            .buttonStyle(SquishStyle())
            .accessibilityLabel("Importer des jeux ou des sauvegardes")
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aucun jeu pour l'instant")
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(Color.capsuleInk)
            Text("Touche + pour importer tes ROM (.gba, .gb, .gbc, .nds) et tes sauvegardes .sav si tu en as. Tu peux aussi les déposer dans le dossier Capsule > ROMs de l'app Fichiers.")
                .font(.subheadline)
                .foregroundStyle(Color.capsuleInk.opacity(0.75))
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: CardColors.stops(.standard), startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    private func pill(_ icon: String, _ title: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.capsuleCream)
            .padding(.horizontal, 18)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background(Color.capsulePanel, in: Capsule())
            .overlay(Capsule().stroke(Color.capsuleCream.opacity(0.08), lineWidth: 1))
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

/// A game on the home screen: its cartridge in 3D, when it was last saved, and its buttons; a tap on the
/// cartridge plays it.
private struct GameCard: View {
    let game: Game
    /// Passed on to the cartridge, which alone redraws as the phone moves.
    let tilt: PhoneTilt
    let play: () -> Void
    let openBank: () -> Void
    let history: () -> Void
    let delete: () -> Void

    /// The cartridge going down into its slot before the game starts.
    @State private var inserting = false
    /// The slot showing under it, a moment before.
    @State private var slotOpen = false

    var body: some View {
        let tint = CapsuleTheme.tint(for: game)
        let kind = CartridgeKind(game)
        VStack(spacing: 16) {
            CartridgeView(game: game, tilt: tilt)
                .frame(maxWidth: kind == .wide ? 330 : 230)
                .scaleEffect(inserting ? 0.94 : 1, anchor: .bottom)
                .offset(y: inserting ? 150 : 0)
                // Its slot: what goes below this edge is inside the console. The mask reaches far up and to the
                // sides, so the cartridge's turn is never cut there.
                .mask(alignment: .bottom) {
                    Rectangle().padding(.top, -300).padding(.horizontal, -120)
                }
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(LinearGradient(colors: [.black, Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
                        .frame(height: 10)
                        .padding(.horizontal, kind == .wide ? 6 : 26)
                        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
                        .opacity(slotOpen ? 1 : 0)
                        .scaleEffect(x: slotOpen ? 1 : 0.6)
                        .offset(y: 4)
                }
                .padding(.top, 10)
                .contentShape(Rectangle())
                .onTapGesture(perform: insertAndPlay)
                .accessibilityElement()
                .accessibilityLabel(CapsuleCard<EmptyView>.displayTitle(game.name))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Jouer", play)
            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("\(game.platformLabel)\n\(CapsuleTheme.savedLine(game.saveURL, now: context.date))")
                        .lineSpacing(3)
                        .smallCaps(.capsuleCream, opacity: 0.55)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                Button(action: insertAndPlay) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Jouer")
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(
                        LinearGradient(colors: [Color(CardColors.accent(tint).mixed(with: .white, 0.25)), Color(CardColors.accent(tint))],
                                       startPoint: .top, endPoint: .bottom),
                        in: Capsule()
                    )
                }
                .buttonStyle(SquishStyle())
                if game.supportsPokemonTools {
                    Button(action: openBank) {
                        GlassCircle(icon: "archivebox")
                    }
                    .buttonStyle(SquishStyle())
                    .disabled(!game.hasSave)
                    .opacity(game.hasSave ? 1 : 0.5)
                    .accessibilityLabel("Boîtes et banque")
                }
                Menu {
                    menuItems
                } label: {
                    GlassCircle(icon: "ellipsis")
                }
                .accessibilityLabel("Plus")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                Color.capsulePanel
                // The game's colour glowing under its cartridge.
                RadialGradient(colors: [Color(red: tint.r, green: tint.g, blue: tint.b).opacity(0.28), .clear],
                               center: UnitPoint(x: 0.5, y: 0.35), startRadius: 0, endRadius: 240)
            }
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(Color.capsuleCream.opacity(0.06), lineWidth: 1))
        .contextMenu { menuItems }
    }

    /// The slot opens, the cartridge clicks in, the game starts; it's back in place for when the game closes.
    private func insertAndPlay() {
        guard !inserting, !slotOpen else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { slotOpen = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeIn(duration: 0.3)) { inserting = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { play() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                inserting = false
                slotOpen = false
            }
        }
    }

    @ViewBuilder private var menuItems: some View {
        if game.hasSave || SafetySave.date(for: game) != nil {
            Button(action: history) {
                Label("Revenir à une sauvegarde", systemImage: "clock.arrow.circlepath")
            }
        }
        Button(role: .destructive, action: delete) {
            Label("Supprimer le jeu", systemImage: "trash")
        }
    }
}

/// The home screen's Pokédex, bank, trades and web tiles.
private struct HomeTile: View {
    let icon: String
    let title: String
    let detail: String
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if let progress = progress {
                    Circle().stroke(Color.capsuleCream.opacity(0.12), lineWidth: 4)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Color.capsuleAccent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.capsuleCream)
            }
            .frame(width: 44, height: 44)
            .background(Color.capsuleCream.opacity(progress == nil ? 0.08 : 0), in: Circle())
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(Color.capsuleCream)
            Text(detail)
                .smallCaps(.capsuleCream, opacity: 0.5)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color.capsulePanel, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.capsuleCream.opacity(0.06), lineWidth: 1))
    }
}
