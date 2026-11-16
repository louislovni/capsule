import SwiftUI

/// The playing screen: picture on top, controller below, a thin bar of tools above.
struct GameView: View {
    @StateObject private var session: EmulatorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingTeam = false
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
                PadRepresentable(showsShoulders: session.isGBA, onKeys: { [weak session] keys in
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
        .sheet(isPresented: $showingTeam) {
            TeamPanel(session: session)
                .presentationDetents([.medium, .large])
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

            Button {
                showingTeam = true
            } label: {
                Label("Équipe", systemImage: "list.bullet.rectangle")
                    .labelStyle(.iconOnly)
            }

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
                    Button("Soigner l'équipe") {
                        session.healParty()
                    }
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

/// The live companion: the team as it is in the game's memory right now.
struct TeamPanel: View {
    @ObservedObject var session: EmulatorSession

    private var teamFootnote: String {
        let heal = "Le soin rend les PV et retire les statuts, hors combat. Les PP ne sont pas restaurés."
        if !session.isGBA {
            return "Jeu Game Boy : l'équipe est recherchée en mémoire (Rouge, Bleu, Jaune, Or, Argent, Cristal). " + heal
        }
        return session.isKnownGame
            ? "Jeu reconnu (\(session.gameLabel)). " + heal
            : "Jeu non répertorié (\(session.gameLabel)) : l'équipe est recherchée automatiquement en mémoire, ce qui peut échouer sur certains hacks."
    }

    var body: some View {
        NavigationStack {
            List {
                if session.party.isEmpty {
                    Text("Aucune équipe détectée pour l'instant. Elle apparaît une fois la partie chargée.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.party) { member in
                        NavigationLink {
                            let rom = session.romData
                            let gameName = session.game.name
                            MonDetailLoader(load: {
                                if let generation = member.generation {
                                    return MonDetails.makeGB(generation: generation, raw: member.raw, party: true,
                                                             sourceGame: gameName)
                                }
                                return MonDetails.make(raw: member.raw, rom: rom)
                            })
                        } label: {
                            TeamRow(member: member)
                        }
                    }
                }
                Section {
                    Button("Soigner l'équipe") {
                        session.healParty()
                    }
                } footer: {
                    Text(teamFootnote)
                }
            }
            .navigationTitle("Équipe")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct TeamRow: View {
    let member: PartyMember

    var body: some View {
        let summary = member.summary
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.isEgg ? "Œuf" : displayName)
                    .font(.headline)
                if summary.isShiny {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Chromatique")
                }
                Spacer()
                if let status = summary.statusLabel {
                    Text(status)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                }
                Text("N. \(summary.level)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if !summary.isEgg {
                ProgressView(value: Double(min(summary.hp, summary.maxHp)), total: Double(max(summary.maxHp, 1)))
                    .tint(hpColor)
                HStack {
                    Text("PV \(summary.hp)/\(summary.maxHp)")
                        .monospacedDigit()
                    Spacer()
                    Text(member.moveNames.joined(separator: " · "))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var displayName: String {
        let nickname = member.summary.nickname
        if nickname.isEmpty || nickname.caseInsensitiveCompare(member.speciesName) == .orderedSame {
            return member.speciesName
        }
        return "\(nickname) (\(member.speciesName))"
    }

    private var hpColor: Color {
        let summary = member.summary
        guard summary.maxHp > 0 else { return .green }
        let ratio = Double(summary.hp) / Double(summary.maxHp)
        if ratio > 0.5 { return .green }
        if ratio > 0.2 { return .yellow }
        return .red
    }
}
