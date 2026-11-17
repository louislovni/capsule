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
            let pictureArea = Self.portraitPictureArea(geometry.size)
            Group {
                if isLandscape {
                    landscapeLayout(bandsBeside: picturesLeavesBands(geometry))
                } else {
                    portraitLayout(pictureArea: pictureArea)
                }
            }
            .onAppear { session.start(landscape: isLandscape, pictureArea: isLandscape ? nil : pictureArea) }
            .onChange(of: isLandscape) { session.setLandscape($0) }
            .onChange(of: geometry.size) { size in
                if size.width <= size.height {
                    session.setPictureArea(Self.portraitPictureArea(size))
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

    /// Upright, the picture's room: the width of the screen, above the controls.
    private static func portraitPictureArea(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: max(size.height - controlZoneHeight(size.height), 100))
    }

    /// Upright: the picture on top, in its own room (PokeDaisy's EXPAND fills it, its HUD
    /// stays in it), and the controller in a zone of its own below, never over the game.
    private func portraitLayout(pictureArea: CGSize) -> some View {
        VStack(spacing: 0) {
            ZStack {
                if session.loadFailed {
                    loadFailure
                } else {
                    screen
                }
            }
            .frame(width: pictureArea.width, height: pictureArea.height)
            .clipped()
            ZStack(alignment: .top) {
                if !session.loadFailed {
                    pad
                }
                toolbar(compact: true)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.09).ignoresSafeArea(edges: .bottom))
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
                        Button("Emplacement \(slot)") {
                            session.saveState(slot: slot)
                        }
                    }
                }
                Section("Charger un état") {
                    ForEach(Self.stateSlots, id: \.self) { slot in
                        Button("Emplacement \(slot)") {
                            requestLoad(slot: slot)
                        }
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
