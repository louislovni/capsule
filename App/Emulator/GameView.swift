import SwiftUI

/// The playing screen: picture on top, controller below, a thin bar of tools above.
struct GameView: View {
    @StateObject private var session: EmulatorSession
    @ObservedObject private var gamepad = GamepadInput.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var userPaused = false
    /// Sideways forced by the plein écran button (works with the rotation lock on).
    @State private var forcedLandscape = false
    @AppStorage(PadSkin.storageKey) private var skinName = PadSkin.capsule.rawValue
    /// The console turning on: black, a white glow, then the game.
    @State private var power = 0

    private var skin: PadSkin { PadSkin(rawValue: skinName) ?? .capsule }

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
                    landscapeLayout(bandsBeside: picturesLeavesBands(geometry), band: bandWidth(geometry))
                } else if skin == .capsule {
                    capsuleLayout(pictureArea: pictureArea, screenHeight: screenHeight)
                } else {
                    portraitLayout(pictureArea: pictureArea, screenHeight: screenHeight)
                }
            }
            .onAppear {
                SafetySave.refresh(session.game)
                SaveHistory.start(session.game)
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
        .overlay {
            ZStack {
                Color.black.opacity(power == 0 ? 1 : 0)
                Color.white.opacity(power == 1 ? 0.55 : 0)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.14).delay(0.08)) { power = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                withAnimation(.easeOut(duration: 0.5)) { power = 2 }
            }
        }
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
                .overlay { dockOverlay(handleOffset: -(Self.cardGap + 8)) }
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
                .overlay(alignment: .trailing) {
                    // The tools' wheel on the edge, solid black, half way down the picture: clear
                    // of PokeDaisy's minimap (top right) and its buttons (bottom right).
                    if !session.loadFailed {
                        CapsuleWheel(tint: session.pictureTint, tools: wheelTools)
                            .offset(y: 20)
                            .touchShield("wheel-upright")
                    }
                }
            ZStack(alignment: .top) {
                if !session.loadFailed && gamepad.controllerName == nil {
                    portraitPad
                }
                toolbar(compact: true)
                    .touchShield("toolbar-upright")
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { dockOverlay(handleOffset: -14).padding(.horizontal, Self.cardGap) }
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
    /// Sideways, the width of the black band each side of the picture (whole screen, points).
    private func bandWidth(_ geometry: GeometryProxy) -> CGFloat {
        let insets = geometry.safeAreaInsets
        let fullWidth = geometry.size.width + insets.leading + insets.trailing
        let fullHeight = geometry.size.height + insets.top + insets.bottom
        return max((fullWidth - fullHeight * session.screenAspect) / 2, 0)
    }

    private func picturesLeavesBands(_ geometry: GeometryProxy) -> Bool {
        let insets = geometry.safeAreaInsets
        let fullWidth = geometry.size.width + insets.leading + insets.trailing
        let fullHeight = geometry.size.height + insets.top + insets.bottom
        return (fullWidth - fullHeight * session.screenAspect) / 2 >= 120
    }

    /// Sideways: the picture as large as the screen allows, the controls over it (or beside it,
    /// in the bands a narrower picture leaves, such as a DS game's).
    private func landscapeLayout(bandsBeside: Bool, band: CGFloat) -> some View {
        let cards = skin == .capsule && bandsBeside && !session.loadFailed
        return ZStack {
            if cards {
                // Capsule sideways: a tinted card in each band, the controls on them.
                HStack(spacing: 0) {
                    bandCard(width: band - 2 * Self.cardGap)
                    Spacer(minLength: 0)
                    bandCard(width: band - 2 * Self.cardGap)
                }
                .padding(Self.cardGap)
                .ignoresSafeArea()
            }
            if session.loadFailed {
                loadFailure
            } else {
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                if gamepad.controllerName == nil {
                    PadRepresentable(isDS: session.game.isDS, pictureAspect: session.screenAspect,
                                     showsShortcuts: false, lightBackdrop: cards, onKeys: { [weak session] keys in
                        session?.setKeys(keys)
                    })
                    .ignoresSafeArea(edges: bandsBeside ? .all : .vertical)
                }
            }
            // The wheel comes down from the top edge, the tools in glass to its left: clear of R and of PokeDaisy's
            // minimap (top right), each in its own frame (an overlay pushed out of the wheel's frame only took a
            // tap now and then, and "…" none).
            VStack {
                if !session.loadFailed {
                    ZStack(alignment: .top) {
                        CapsuleWheel(tint: session.pictureTint, tools: wheelTools, horizontal: true)
                            .touchShield("wheel-sideways")
                        HStack(alignment: .top, spacing: 0) {
                            HStack(spacing: 0) {
                                Spacer(minLength: 0)
                                toolbar(compact: true)
                                    .padding(.horizontal, 14)
                                    .glassCapsule()
                                    .fixedSize()
                                    .touchShield("toolbar-sideways")
                                    .padding(.top, 8)
                                    .padding(.trailing, 164 / 2 + 10)
                            }
                            .frame(maxWidth: .infinity)
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                } else {
                    toolbar(compact: false)
                        .glassCapsule()
                        .fixedSize()
                }
                Spacer()
            }
            .ignoresSafeArea(edges: .top)
        }
        .overlay {
            // Sideways: the panel in the middle, over the picture's lower part; its button at the bottom edge.
            GeometryReader { g in
                let height = g.size.height * 0.92
                let width = min(g.size.width * 0.62, height * 1.1)
                ZStack(alignment: .bottom) {
                    if session.dockOpen {
                        DockPanel(session: session, size: CGSize(width: width, height: height))
                            .frame(width: width, height: height)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if session.dockAvailable && !session.loadFailed {
                        DockHandleButton(session: session)
                            .padding(.bottom, 4)
                    }
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
            }
        }
    }

    /// Upright: PokeDaisy's menus in a panel over the controls (their room), or the button that opens it above them.
    private func dockOverlay(handleOffset: CGFloat) -> some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                if session.dockOpen {
                    DockPanel(session: session, size: g.size)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if session.dockAvailable && !session.loadFailed {
                    DockHandleButton(session: session)
                        .offset(y: handleOffset)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
        }
    }

    private func bandCard(width: CGFloat) -> some View {
        TintedBackground(tint: session.pictureTint)
            .frame(width: max(width, 0))
            .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
    }


    private var screen: some View {
        ScreenRepresentable(session: session)
            .aspectRatio(session.screenAspect, contentMode: .fit)
            .overlay(alignment: .bottom) { noticeBanner }
    }

    /// Upright, the DS shortcuts are on the wheel.
    private var portraitPad: some View {
        PadRepresentable(isDS: session.game.isDS, pictureAspect: session.screenAspect, showsShortcuts: false,
                         onKeys: { [weak session] keys in
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

    /// The menu behind "…": the controller's look, restarting. No save states: one save per
    /// game, the game's own (the player's rule: the adventure as it is).
    @ViewBuilder
    private var moreMenu: some View {
        if let info = session.companionInfo {
            Section("PokeDaisy") {
                Text(info)
            }
        }
        Section {
            Button("Redémarrer le jeu", role: .destructive) {
                session.reset()
            }
        } footer: {
            Text("Ce qui n'est pas sauvegardé dans le jeu sera perdu.")
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
}
