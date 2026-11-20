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
    /// The hack patcher, with the patch picked through + if there was one.
    @State private var patching: PatchRequest?
    /// The game being started: its cartridge out of its card, full screen, going into the console.
    @State private var launching: Game?
    @State private var launchStep = 0
    @State private var launchClipped = false
    @Namespace private var cartridges

    struct PatchRequest: Identifiable {
        let id = UUID()
        let patch: URL?
    }

    enum Route: Hashable {
        case pokedex, bank, account, settings, gamepad, compat
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
                case .compat:
                    CompatView(games: library.games)
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
            .sheet(item: $patching) { request in
                PatchView(games: library.games, initialPatch: request.patch) { name in
                    library.refresh()
                    message = "\(name) est dans ta bibliothèque."
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
            .onReceive(NotificationCenter.default.publisher(for: CloudSync.saveWritten)) { note in
                // A save made in the game goes up a few seconds later (the game keeps running).
                if let file = note.object as? String {
                    Task { await cloud.push(file) }
                }
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
                    GameCard(game: game, tilt: tilt, cartridges: cartridges, launching: launching == game,
                             play: { launch(game) },
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
                    NavigationLink(value: Route.compat) {
                        pill("checklist", "Jeux compatibles")
                    }
                    Button {
                        patching = PatchRequest(patch: nil)
                    } label: {
                        pill("bandage", "Patcher un hack")
                    }
                }
                .buttonStyle(SquishStyle())
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
        .overlay { launchOverlay }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { tilt.start() }
        .onDisappear { tilt.stop() }
        .onChange(of: playing) { game in
            if game == nil { tilt.start() } else { tilt.stop() }
        }
    }

    // MARK: Starting a game

    /// Full screen: the cartridge comes out of its card to the middle, then goes down into the console's slot; the
    /// slot's light comes on and the game starts.
    @ViewBuilder private var launchOverlay: some View {
        if let game = launching {
            let kind = CartridgeKind(game)
            GeometryReader { geometry in
                let width = min(geometry.size.width * (kind == .wide ? 0.82 : 0.62), 420)
                let height = width / kind.aspect
                let slotY = geometry.size.height * 0.66
                ZStack(alignment: .top) {
                    Color.black.opacity(launchStep >= 1 ? 0.96 : 0)
                    // The cartridge, its bottom going under the slot's edge (once it's above the slot: on its way
                    // from its card nothing cuts it).
                    VStack(spacing: 0) {
                        Color.clear.frame(height: launchStep >= 2 ? slotY - 30 : slotY - height - 70)
                        CartridgeFace(game: game)
                            .frame(width: width, height: height + 16)
                            .matchedGeometryEffect(id: game.id, in: cartridges)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .mask(alignment: .top) {
                        Rectangle().frame(height: launchClipped ? slotY : geometry.size.height + 400)
                    }
                    // The console's slot and its light.
                    VStack(spacing: 18) {
                        Capsule()
                            .fill(LinearGradient(colors: [.black, Color(white: 0.2)], startPoint: .top, endPoint: .bottom))
                            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
                            .frame(width: width + 24, height: 14)
                        Circle()
                            .fill(launchStep >= 3 ? Color(red: 0.35, green: 1, blue: 0.5) : Color(white: 0.18))
                            .frame(width: 10, height: 10)
                            .shadow(color: launchStep >= 3 ? Color(red: 0.35, green: 1, blue: 0.5) : .clear, radius: 8)
                    }
                    .offset(y: slotY - 7)
                    .opacity(launchStep >= 1 ? 1 : 0)
                    .scaleEffect(x: launchStep >= 1 ? 1 : 0.7)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(true)
        }
    }

    private func launch(_ game: Game) {
        guard launching == nil else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            launching = game
            launchStep = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { launchClipped = true }
            withAnimation(.easeIn(duration: 0.32)) { launchStep = 2 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.92) {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            withAnimation(.easeOut(duration: 0.15)) { launchStep = 3 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
            // No slide-up: the game's screen turns on where the cartridge went in (GameView).
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { playing = game }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                launching = nil
                launchStep = 0
                launchClipped = false
            }
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
                if cloud.enabled, account.user != nil {
                    Button {
                        path.append(.account)
                    } label: {
                        SyncBadge(cloud: cloud)
                    }
                    .buttonStyle(SquishStyle())
                    .padding(.top, 4)
                }
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
            Text("Touche + pour importer tes ROM (.gba, .gb, .gbc, .nds), tes sauvegardes .sav si tu en as, ou un patch de hack (.ips, .ups, .bps, .xdelta). Tu peux aussi les déposer dans le dossier Capsule > ROMs de l'app Fichiers.")
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
        case .success(let picked):
            // Patches go to the patcher (the first one: one hack at a time), copied while the pick allows it.
            let patches = picked.filter { PatchView.extensions.contains($0.pathExtension.lowercased()) }
            let urls = picked.filter { !PatchView.extensions.contains($0.pathExtension.lowercased()) }
            if let first = patches.first {
                let scoped = first.startAccessingSecurityScopedResource()
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(first.lastPathComponent)
                try? FileManager.default.removeItem(at: copy)
                if (try? FileManager.default.copyItem(at: first, to: copy)) != nil {
                    patching = PatchRequest(patch: copy)
                }
                if scoped { first.stopAccessingSecurityScopedResource() }
                if urls.isEmpty { return }
            }
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
    let cartridges: Namespace.ID
    /// Its cartridge is out, full screen (LibraryView.launchOverlay).
    let launching: Bool
    let play: () -> Void
    let openBank: () -> Void
    let history: () -> Void
    let delete: () -> Void

    var body: some View {
        let tint = CapsuleTheme.tint(for: game)
        let kind = CartridgeKind(game)
        VStack(spacing: 16) {
            ZStack {
                if launching {
                    // Its place kept while it's out.
                    CartridgeFace(game: game).hidden()
                } else {
                    CartridgeView(game: game, tilt: tilt)
                        .matchedGeometryEffect(id: game.id, in: cartridges)
                }
            }
            .frame(maxWidth: kind == .wide ? 330 : 230)
                .padding(.top, 10)
                .contentShape(Rectangle())
                .onTapGesture(perform: play)
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
                Button(action: play) {
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
