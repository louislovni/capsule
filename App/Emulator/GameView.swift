import SwiftUI

/// The playing screen: picture on top, controller below, a thin bar of tools above.
struct GameView: View {
    @StateObject private var session: EmulatorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var staleStateSlot: Int?
    @State private var userPaused = false

    private static let stateSlots = [1, 2, 3]

    init(game: Game) {
        _session = StateObject(wrappedValue: EmulatorSession(game: game))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if session.loadFailed {
                loadFailure
            } else {
                ScreenRepresentable(session: session)
                    .aspectRatio(session.screenAspect, contentMode: .fit)
                    .overlay(alignment: .bottom) { noticeBanner }
                PadRepresentable(onKeys: { [weak session] keys in
                    session?.setKeys(keys)
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { session.start() }
        .onDisappear { session.stop() }
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

    // MARK: - Pieces

    private var toolbar: some View {
        HStack(spacing: 18) {
            Button {
                dismiss()
            } label: {
                Label("Quitter", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }

            Spacer()

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
        .font(.title3)
        .tint(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = session.notice {
            Text(notice)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.7), in: Capsule())
                .foregroundStyle(.white)
                .padding(.bottom, 8)
                .task(id: notice) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
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
            Text("Vérifie qu'il s'agit bien d'une ROM Game Boy Advance (.gba), Game Boy (.gb) ou Game Boy Color (.gbc), non compressée.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
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
