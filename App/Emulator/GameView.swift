import SwiftUI

/// The playing screen: picture on top, controller below, a thin bar of tools above.
struct GameView: View {
    @StateObject private var session: EmulatorSession
    @ObservedObject private var gamepad = GamepadInput.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var staleStateSlot: Int?
    @State private var userPaused = false
    /// Sideways forced by the plein écran button (works with the rotation lock on).
    @State private var forcedLandscape = false
    @AppStorage(PadSkin.storageKey) private var skinName = PadSkin.capsule.rawValue

    private var skin: PadSkin { PadSkin(rawValue: skinName) ?? .capsule }

    private static let stateSlots = [1, 2, 3]

    init(game: Game) {
        _session = StateObject(wrappedValue: EmulatorSession(game: game))
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let topInset = geometry.safeAreaInsets.top
            let screenHeight = geometry.size.height + topInset + geometry.safeAreaInsets.bottom
            let pictureArea = portraitPictureArea(geometry.size, topInset: topInset, screenHeight: screenHeight)
            Group {
                if isLandscape {
                    landscapeLayout(bandsBeside: picturesLeavesBands(geometry))
                } else if skin == .capsule {
                    capsuleLayout(pictureArea: pictureArea, screenHeight: screenHeight)
                } else {
                    portraitLayout(pictureArea: pictureArea, screenHeight: screenHeight)
                }
            }
            .onAppear {
                gamepad.onKeys = { [weak session] keys in session?.setControllerKeys(keys) }
                gamepad.onSpeed = { [weak session] in session?.cycleSpeed() }
                session.start(landscape: isLandscape, pictureArea: isLandscape ? nil : pictureArea,
                              screenHeight: isLandscape || skin == .capsule ? nil : screenHeight, topInset: topInset)
            }
            .onChange(of: isLandscape) { session.setLandscape($0) }
            .onChange(of: geometry.size) { _ in updatePictureArea(geometry) }
            .onChange(of: skinName) { _ in updatePictureArea(geometry) }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onChange(of: gamepad.controllerName) { name in
            session.setControllerKeys(0)
            session.notice = name.map { "\($0) connectée" } ?? "Manette déconnectée"
        }
        .onDisappear {
            gamepad.onKeys = nil
            gamepad.onSpeed = nil
            session.stop()
            if forcedLandscape {
                Orientation.force(landscape: false)
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                session.setPaused(userPaused)
            } else {
                session.setPaused(true)
            }
        }
        .alert("État antérieur à un transfert", isPresented: staleAlertBinding) {
            Button("Charger quand même", role: .destructive) {
                if let slot = staleStateSlot {
                    session.loadState(slot: slot)
                }
                staleStateSlot = nil
            }
            Button("Annuler", role: .cancel) {
                staleStateSlot = nil
            }
        } message: {
            Text("Cet état date d'avant ton dernier échange avec la banque. Si tu le charges puis sauvegardes dans le jeu, le PC reviendra à son contenu d'avant : des Pokémon retirés de la banque peuvent être perdus, ou des Pokémon déposés dupliqués.")
        }
    }

    /// When the state in this slot was saved (nil: none yet).
    private func stateDate(_ slot: Int) -> Date? {
        let url = session.game.stateURL(slot: slot)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// "Emplacement 2" over "17 nov. à 17:32", or "vide".
    private func slotLabel(_ slot: Int) -> some View {
        let subtitle: String
        if let date = stateDate(slot) {
            subtitle = Calendar.current.isDateInToday(date)
                ? "Aujourd'hui à \(date.formatted(date: .omitted, time: .shortened))"
                : date.formatted(date: .abbreviated, time: .shortened)
        } else {
            subtitle = "vide"
        }
        return Label {
            Text("Emplacement \(slot)")
            Text(subtitle)
        } icon: {
            Image(systemName: stateDate(slot) == nil ? "square.dashed" : "clock.arrow.circlepath")
        }
    }

    private var staleAlertBinding: Binding<Bool> {
        Binding(
            get: { staleStateSlot != nil },
            set: { shown in
                if !shown {
                    staleStateSlot = nil
                }
            }
        )
    }

    // MARK: - Layouts

    /// Upright, the controls' own zone under the picture (points, without the home indicator's).
    private static func controlZoneHeight(_ height: CGFloat) -> CGFloat {
        min(max(height * 0.42, 300), 380)
    }

    /// The Capsule card's height, for the whole screen's height (points).
    private static func cardHeight(_ screenHeight: CGFloat) -> CGFloat {
        min(max(screenHeight * 0.51, 400), 440)
    }

    /// Black between the picture and the card, and around the card.
    private static let cardGap: CGFloat = 5

    /// Upright, the picture's room: the width of the screen, from its top edge (under the
    /// Dynamic Island too) down to the controls (the plain skin) or the card (Capsule's).
    private func portraitPictureArea(_ size: CGSize, topInset: CGFloat, screenHeight: CGFloat) -> CGSize {
        if skin == .capsule {
            let height = screenHeight - Self.cardHeight(screenHeight) - 2 * Self.cardGap
            return CGSize(width: size.width, height: max(height, 100))
        }
        return CGSize(width: size.width, height: max(size.height + topInset - Self.controlZoneHeight(size.height), 100))
    }

    private func updatePictureArea(_ geometry: GeometryProxy) {
        let size = geometry.size
        guard size.width <= size.height else { return }
        let insets = geometry.safeAreaInsets
        let full = size.height + insets.top + insets.bottom
        session.setPictureArea(portraitPictureArea(size, topInset: insets.top, screenHeight: full),
                               screenHeight: skin == .capsule ? nil : full,
                               topInset: insets.top)
    }

    /// Upright with the Capsule skin: the picture in the black on top, the card below it.
    private func capsuleLayout(pictureArea: CGSize, screenHeight: CGFloat) -> some View {
        VStack(spacing: Self.cardGap) {
            Group {
                if session.loadFailed {
                    loadFailure
                } else {
                    screen
                }
            }
            .frame(width: pictureArea.width, height: pictureArea.height)
            .clipped()
            CapsuleCard(session: session,
                        showsControls: !session.loadFailed && gamepad.controllerName == nil,
                        tools: wheelTools,
                        onQuit: { dismiss() },
                        menu: { moreMenu })
                .frame(height: Self.cardHeight(screenHeight))
                .padding(.horizontal, Self.cardGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    /// The side wheel's tools. On a DS game, PokeDaisy's own buttons first: its DS core opens
    /// the companion on L2, the quick menu on SELECT + L2, steps the screen layouts on R2 and
    /// floats the touch screen in on SELECT + R2.
    private var wheelTools: [WheelTool] {
        var tools: [WheelTool] = []
        if session.game.isDS {
            tools += [
                WheelTool(id: "Compagnon", short: "COMP.", icon: "sparkles") { session.pulse(PadKey.l2) },
                WheelTool(id: "Menu rapide", short: "MENU", icon: "square.grid.2x2") { session.pulse(PadKey.select | PadKey.l2) },
                WheelTool(id: "Disposition des écrans", short: "ÉCRANS", icon: "rectangle.split.1x2") { session.pulse(PadKey.r2) },
                WheelTool(id: "Écran tactile", short: "TACT.", icon: "hand.point.up.left") { session.pulse(PadKey.select | PadKey.r2) },
            ]
        }
        tools += [
            WheelTool(id: "Sauvegarde rapide", short: "SAUV.", icon: "square.and.arrow.down") { session.saveState(slot: 1) },
            WheelTool(id: "Charger la sauvegarde rapide", short: "CHARG.", icon: "clock.arrow.circlepath") { requestLoad(slot: 1) },
            WheelTool(id: session.isPaused ? "Reprendre" : "Pause", short: session.isPaused ? "REPR." : "PAUSE", icon: session.isPaused ? "play.fill" : "pause.fill") {
                userPaused.toggle()
                session.setPaused(userPaused)
            },
            WheelTool(id: "Plein écran", short: "PLEIN", icon: "arrow.up.left.and.arrow.down.right") {
                forcedLandscape.toggle()
                Orientation.force(landscape: forcedLandscape)
            },
        ]
        return tools
    }

    /// Upright: the picture from the top, its HUD and the player in the part clear of the
    /// controls (PokeDaisy is told that part); a DS game's EXPAND runs on under the controls to
    /// the screen's bottom edge. The controls lie over it on a shade that darkens downwards.
    private func portraitLayout(pictureArea: CGSize, screenHeight: CGFloat) -> some View {
        // The controls set the layout (the clear part, then their zone, within the screen); the
        // picture lies behind as a background, so its height (the whole screen) can't push them out.
        VStack(spacing: 0) {
            Color.clear
                .frame(height: pictureArea.height)
            ZStack(alignment: .top) {
                if !session.loadFailed && gamepad.controllerName == nil {
                    pad
                }
                toolbar(compact: true)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(alignment: .top) {
                // A shade that comes in gradually from above the controls, darkest at the bottom.
                LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                       .init(color: .black.opacity(0.35), location: 0.3),
                                       .init(color: .black.opacity(0.6), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.top, -60)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
        .background(alignment: .top) {
            Group {
                if session.loadFailed {
                    loadFailure
                        .frame(width: pictureArea.width, height: pictureArea.height)
                        .frame(width: pictureArea.width, height: screenHeight, alignment: .top)
                } else if let tall = session.tallCanvas {
                    // A GBA / Game Boy canvas taller than the screen: its bottom part, to the bottom edge.
                    let points = tall.height / UIScreen.main.scale
                    screen
                        .frame(width: pictureArea.width, height: points)
                        .frame(width: pictureArea.width, height: screenHeight, alignment: .bottom)
                } else {
                    screen
                        .frame(width: pictureArea.width,
                               height: session.game.isDS ? screenHeight : pictureArea.height,
                               alignment: .top)
                        .frame(width: pictureArea.width, height: screenHeight, alignment: .top)
                }
            }
            .clipped()
            .ignoresSafeArea()
        }
    }

    /// Sideways, whether the picture (full height) leaves black bands wide enough for the controls.
    private func picturesLeavesBands(_ geometry: GeometryProxy) -> Bool {
        let insets = geometry.safeAreaInsets
        let fullWidth = geometry.size.width + insets.leading + insets.trailing
        let fullHeight = geometry.size.height + insets.top + insets.bottom
        return (fullWidth - fullHeight * session.screenAspect) / 2 >= 120
    }

    /// Sideways: the picture as large as the screen allows, the controls over it (or beside it,
    /// in the bands a narrower picture leaves, such as a DS game's).
    private func landscapeLayout(bandsBeside: Bool) -> some View {
        ZStack {
            if session.loadFailed {
                loadFailure
            } else {
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                if gamepad.controllerName == nil {
                    pad
                        .ignoresSafeArea(edges: bandsBeside ? .all : .vertical)
                }
            }
            VStack {
                toolbar(compact: false)
                    .background(Color.black.opacity(0.35), in: Capsule())
                    .fixedSize()
                Spacer()
            }
        }
    }

    private var screen: some View {
        ScreenRepresentable(session: session)
            .aspectRatio(session.screenAspect, contentMode: .fit)
            .overlay(alignment: .bottom) { noticeBanner }
    }

    private var pad: some View {
        PadRepresentable(isDS: session.game.isDS, pictureAspect: session.screenAspect, onKeys: { [weak session] keys in
            session?.setKeys(keys)
        })
    }

    // MARK: - Pieces

    /// Quit, plein écran, pause, speed and the menu. Compact upright: between L and R.
    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: compact ? 14 : 18) {
            Button {
                dismiss()
            } label: {
                Label("Quitter", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }

            if !compact {
                Spacer()
            }

            Button {
                forcedLandscape.toggle()
                Orientation.force(landscape: forcedLandscape)
            } label: {
                Label(forcedLandscape ? "Quitter le plein écran" : "Plein écran",
                      systemImage: forcedLandscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .labelStyle(.iconOnly)
            }

            Button {
                userPaused.toggle()
                session.setPaused(userPaused)
            } label: {
                Label(session.isPaused ? "Reprendre" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                    .labelStyle(.iconOnly)
            }

            Button {
                session.cycleSpeed()
            } label: {
                Text("\(session.speed)×")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 30)
            }
            .accessibilityLabel("Vitesse \(session.speed) fois")


            Menu {
                moreMenu
            } label: {
                Label("Plus", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
        }
        .font(compact ? .body : .title3)
        .tint(.white)
        .padding(.horizontal, compact ? 0 : 18)
        .padding(.vertical, compact ? 6 : 8)
        .fixedSize()
    }

    /// The menu behind "…": save states, the controller's look, restarting.
    @ViewBuilder
    private var moreMenu: some View {
        if let info = session.companionInfo {
            Section("PokeDaisy") {
                Text(info)
            }
        }
        Section("Enregistrer un état") {
            ForEach(Self.stateSlots, id: \.self) { slot in
                Button {
                    session.saveState(slot: slot)
                } label: {
                    slotLabel(slot)
                }
            }
        }
        Section("Charger un état") {
            ForEach(Self.stateSlots, id: \.self) { slot in
                Button {
                    requestLoad(slot: slot)
                } label: {
                    slotLabel(slot)
                }
                .disabled(stateDate(slot) == nil)
            }
        }
        Section {
            Button("Redémarrer le jeu", role: .destructive) {
                session.reset()
            }
        }
        Section {
            // One line that opens the choice, so the menu stays short.
            Picker(selection: $skinName) {
                ForEach(PadSkin.allCases) { skin in
                    Text(skin.title).tag(skin.rawValue)
                }
            } label: {
                Label("Apparence de la manette", systemImage: "gamecontroller")
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = session.notice {
            Text(notice)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
                .padding(.bottom, 8)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .task(id: notice) {
                    // Long messages (PokeDaisy's verdict on the ROM) stay long enough to be read.
                    let seconds: UInt64 = notice.count > 60 ? 8 : 2
                    try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                    if session.notice == notice {
                        session.notice = nil
                    }
                }
        }
    }

    private var loadFailure: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text("Ce fichier n'a pas pu être lancé")
                .font(.headline)
            Text("Vérifie qu'il s'agit bien d'une ROM Game Boy Advance (.gba), Game Boy (.gb), Game Boy Color (.gbc) ou Nintendo DS (.nds), non compressée.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if !session.loadError.isEmpty {
                Text(session.loadError)
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Loading a state from before a bank transfer would bring the old PC back.
    private func requestLoad(slot: Int) {
        let game = session.game
        if let transfer = game.lastBankTransfer,
           let saved = Storage.modificationDate(of: game.stateURL(slot: slot)),
           saved < transfer {
            staleStateSlot = slot
        } else {
            session.loadState(slot: slot)
        }
    }
}
