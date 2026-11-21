import SwiftUI

/// "Jouer à deux": pick your Emerald game, pair it with a player nearby (both on the same Wi-Fi), then play: each sees
/// the other's hero on the map. PokeDaisy's co-op, so it also pairs with its Android app.
struct CoopView: View {
    let games: [Game]

    @ObservedObject private var coop = CoopService.shared
    @State private var candidates: [Game] = []
    @State private var checked = false
    @State private var picked: Game?
    @State private var pairing = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Vous vous voyez sur la carte, chacun dans sa propre partie", systemImage: "person.2")
                    Label("Pokémon Émeraude, la même version des deux côtés (française ou anglaise)", systemImage: "gamecontroller")
                    Label("Sur le même Wi-Fi pour l'instant", systemImage: "wifi")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Ta partie") {
                if !checked {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Recherche d'Émeraude dans tes jeux…").foregroundStyle(.secondary)
                    }
                } else if candidates.isEmpty {
                    Text("Aucun Pokémon Émeraude compatible dans tes jeux (la cartouche d'origine, en français ou en anglais).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { game in
                        Button {
                            pick(game)
                        } label: {
                            HStack {
                                Text(GameTitles.shared.title(for: game))
                                Spacer()
                                if picked == game {
                                    Image(systemName: "checkmark").foregroundStyle(Color.capsuleAccent)
                                }
                            }
                        }
                    }
                    if picked != nil && !coop.gameReady {
                        Text("Lance d'abord cette partie et sauvegarde une fois : il faut un dresseur dans la sauvegarde.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let current = coop.pairs.first(where: { $0.current }), picked != nil {
                Section("Ton partenaire") {
                    Label(current.partner, systemImage: "person.fill.checkmark")
                    Text("Lancez Émeraude chacun de votre côté, sur le même Wi-Fi : vous vous verrez sur la carte.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Oublier ce partenaire", role: .destructive) {
                        coop.forget(current)
                    }
                }
            } else if picked != nil && coop.gameReady {
                pairingSection
            }

            let others = coop.pairs.filter { !$0.current }
            if !others.isEmpty {
                Section("Autres partenaires") {
                    ForEach(others) { pair in
                        HStack {
                            Text(pair.partner)
                            Spacer()
                            Button("Oublier", role: .destructive) { coop.forget(pair) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Jouer à deux")
        .capsuleScreen()
        .task { await findGames() }
        .onDisappear {
            if pairing {
                coop.closePairing()
            }
        }
        .alert("Jouer avec \(coop.partnerName) ?", isPresented: Binding(
            get: { coop.pairStep == Int32(COOP_PAIR_CONFIRM) },
            set: { _ in })
        ) {
            Button("Accepter") { coop.accept() }
            Button("Refuser", role: .cancel) { coop.deny() }
        } message: {
            Text("Dresseur \(coop.partnerName), ID \(String(format: "%05d", coop.partnerTrainerId)). Accepte seulement si c'est bien la personne avec qui tu veux jouer.")
        }
    }

    @ViewBuilder private var pairingSection: some View {
        Section("Associer avec un joueur proche") {
            switch coop.pairStep {
            case Int32(COOP_PAIR_INVITING):
                Text("Sur l'autre appareil, ouvre aussi « Jouer à deux » avec Émeraude. Il apparaît ici : touche-le pour l'inviter, ou attends qu'il te choisisse.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if coop.nearby.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Recherche sur le Wi-Fi…").foregroundStyle(.secondary)
                    }
                }
                ForEach(coop.nearby) { player in
                    Button {
                        coop.join(player)
                    } label: {
                        Label(player.label.isEmpty ? "Joueur" : player.label, systemImage: "person.wave.2")
                    }
                }
            case Int32(COOP_PAIR_CONNECTING):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connexion…")
                }
            case Int32(COOP_PAIR_CONFIRM):
                Text("Réponds à la question.")
            case Int32(COOP_PAIR_WAITING):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("En attente de \(coop.partnerName)…")
                }
            case Int32(COOP_PAIR_PAIRED):
                Label("Associé avec \(coop.partnerName)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case Int32(COOP_PAIR_FAILED):
                Text(failText).foregroundStyle(.secondary)
                Button("Réessayer") { start() }
            default:
                Button {
                    start()
                } label: {
                    Label("Associer", systemImage: "link")
                }
            }
        }
    }

    private var failText: String {
        switch coop.pairFail {
        case Int32(COOP_FAIL_VERSION): return "L'autre appareil a une version de la coop différente : mets à jour les deux apps."
        case Int32(COOP_FAIL_DIFFERENT_ROM): return "L'autre joueur n'a pas la même version d'Émeraude."
        case Int32(COOP_FAIL_SAME_SAVE): return "C'est la même sauvegarde des deux côtés : chacun doit avoir sa propre partie."
        case Int32(COOP_FAIL_SAVE_ALREADY_PAIRED): return "Cette partie a déjà un partenaire."
        case Int32(COOP_FAIL_DENIED): return "L'association a été refusée."
        case Int32(COOP_FAIL_TIMEOUT): return "Pas de réponse à temps."
        case Int32(COOP_FAIL_NO_GAME): return "Choisis d'abord ta partie."
        default: return "La connexion n'a pas abouti. Vérifiez que vous êtes sur le même Wi-Fi."
        }
    }

    private func start() {
        pairing = true
        coop.openPairing()
    }

    private func pick(_ game: Game) {
        if pairing {
            coop.closePairing()
            pairing = false
        }
        picked = game
        coop.use(game)
    }

    private func findGames() async {
        var found: [Game] = []
        for game in games where await CoopService.isCoopGame(game) {
            found.append(game)
        }
        candidates = found
        checked = true
        if picked == nil, let first = found.first {
            pick(first)
        }
    }
}
