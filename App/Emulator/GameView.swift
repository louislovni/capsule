import SwiftUI

/// The playing screen: picture on top, controller below, a thin bar of tools above.
struct GameView: View {
    @StateObject private var session: EmulatorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var staleStateSlot: Int?
    @State private var userPaused = false
    /// Sideways forced by the plein écran button (works with the rotation lock on).
    @State private var forcedLandscape = false

    private static let stateSlots = [1, 2, 3]

    init(game: Game) {
        _session = StateObject(wrappedValue: EmulatorSession(game: game))
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let topInset = geometry.safeAreaInsets.top
            let pictureArea = Self.portraitPictureArea(geometry.size, topInset: topInset)
            let screenHeight = geometry.size.height + topInset + geometry.safeAreaInsets.bottom
            Group {
                if isLandscape {
                    landscapeLayout(bandsBeside: picturesLeavesBands(geometry))
                } else {
                    portraitLayout(pictureArea: pictureArea, screenHeight: screenHeight)
                }
            }
            .onAppear {
                session.start(landscape: isLandscape, pictureArea: isLandscape ? nil : pictureArea,
                              screenHeight: isLandscape ? nil : screenHeight)
            }
            .onChange(of: isLandscape) { session.setLandscape($0) }
            .onChange(of: geometry.size) { size in
                if size.width <= size.height {
                    let insets = geometry.safeAreaInsets
                    session.setPictureArea(Self.portraitPictureArea(size, topInset: insets.top),
                                           screenHeight: size.height + insets.top + insets.bottom)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onDisappear {
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

    /// Upright, the picture's room: the width of the screen, from its top edge (under the
    /// Dynamic Island too) down to the controls.
    private static func portraitPictureArea(_ size: CGSize, topInset: CGFloat) -> CGSize {
        CGSize(width: size.width, height: max(size.height + topInset - controlZoneHeight(size.height), 100))
    }

    /// Upright: the picture from the top, its HUD and the player in the part clear of the
    /// controls (PokeDaisy is told that part); a DS game's EXPAND runs on under the controls to
    /// the screen's bottom edge. The controls lie over it on a shade that darkens downwards.
    private func portraitLayout(pictureArea: CGSize, screenHeight: CGFloat) -> some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                if session.loadFailed {
                    loadFailure
                        .frame(height: pictureArea.height)
                } else {
                    screen
                }
            }
            .frame(width: pictureArea.width,
                   height: session.game.isDS ? screenHeight : pictureArea.height,
                   alignment: .top)
            .clipped()
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: pictureArea.height)
                ZStack(alignment: .top) {
                    if !session.loadFailed {
                        pad
                    }
                    toolbar(compact: true)
                        .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    LinearGradient(colors: [Color.black.opacity(0.15), Color.black.opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                )
            }
            .ignoresSafeArea(edges: .top)
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
                pad
                    .ignoresSafeArea(edges: bandsBeside ? .all : .vertical)
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
