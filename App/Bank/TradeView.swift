import MultipeerConnectivity
import SwiftUI

/// Trading with an iPhone nearby: find it, put up a Pokémon from the bank, see the other's,
/// both confirm.
struct TradeView: View {
    @ObservedObject var bank: BankStore
    @StateObject private var trade: TradeSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = TradeSession.displayName

    init(bank: BankStore) {
        self.bank = bank
        _trade = StateObject(wrappedValue: TradeSession(bank: bank))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Échange")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fermer") {
                            trade.stop()
                            dismiss()
                        }
                    }
                }
        }
        .onAppear { trade.start() }
        .onDisappear { trade.stop() }
        .alert(item: $trade.invitation) { invitation in
            Alert(title: Text("\(invitation.name) veut échanger"),
                  message: Text("Accepter l'échange avec cet iPhone ?"),
                  primaryButton: .default(Text("Accepter")) { invitation.answer(true) },
                  secondaryButton: .cancel(Text("Refuser")) { invitation.answer(false) })
        }
    }

    @ViewBuilder
    private var content: some View {
        switch trade.phase {
        case .searching:
            searching
        case .connecting(let peer):
            VStack(spacing: 14) {
                ProgressView()
                Text("Connexion avec \(peer)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .connected(let peer):
            table(peer: peer)
        case .finished(let received, let given):
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("Échange terminé !")
                    .font(.title2.weight(.semibold))
                Text("\(received) a rejoint ta banque, à la place de \(given).")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Nouvel échange") {
                    trade.restart()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let reason):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text(reason)
                    .multilineTextAlignment(.center)
                Button("Réessayer") {
                    trade.restart()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var searching: some View {
        List {
            Section {
                TextField("Ton nom", text: $name)
                    .submitLabel(.done)
                    .onSubmit {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, trimmed != TradeSession.displayName else { return }
                        trade.rename(trimmed)
                    }
            } header: {
                Text("Ton nom")
            } footer: {
                Text("C'est le nom que l'autre iPhone voit.")
            }
            Section {
                if trade.nearby.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Recherche des iPhones proches…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(trade.nearby, id: \.self) { peer in
                        Button {
                            trade.invite(peer)
                        } label: {
                            Label(peer.displayName, systemImage: "iphone")
                        }
                    }
                }
            } header: {
                Text("À proximité")
            } footer: {
                Text("Ouvre aussi Banque > Échanger sur l'autre iPhone, puis touche son nom ici. Le Bluetooth et le Wi-Fi doivent être activés sur les deux.")
            }
        }
    }

    private func table(peer: String) -> some View {
        List {
            Section {
                if let mine = trade.myOffer {
                    NavigationLink {
                        TradePicker(entries: bank.entries) { trade.offer($0) }
                    } label: {
                        BankEntryRow(entry: mine)
                    }
                } else {
                    NavigationLink {
                        TradePicker(entries: bank.entries) { trade.offer($0) }
                    } label: {
                        Label("Choisir un Pokémon", systemImage: "plus.circle")
                    }
                    .disabled(bank.entries.isEmpty)
                }
            } header: {
                Text("Tu donnes")
            } footer: {
                if bank.entries.isEmpty {
                    Text("Ta banque est vide : dépose d'abord un Pokémon depuis la boîte d'un jeu.")
                }
            }

            Section {
                if let theirs = trade.theirOffer {
                    NavigationLink {
                        MonDetailLoader(load: { theirs.resolvedDetails() })
                    } label: {
                        BankEntryRow(entry: theirs)
                    }
                } else {
                    Text("\(peer) n'a pas encore choisi.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Tu reçois de \(peer)")
            }

            Section {
                Button {
                    trade.confirm()
                } label: {
                    Text(trade.iConfirmed ? "Validé" : "Valider l'échange")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trade.myOffer == nil || trade.theirOffer == nil || trade.iConfirmed)
                .listRowBackground(Color.clear)
            } footer: {
                Text(status(peer: peer))
            }
        }
    }

    private func status(peer: String) -> String {
        switch (trade.iConfirmed, trade.theyConfirmed) {
        case (true, false): return "En attente de \(peer)…"
        case (false, true): return "\(peer) a validé : à toi."
        default: return "L'échange se fait quand vous avez validé tous les deux. Changer de Pokémon annule les validations."
        }
    }
}

/// The bank, to pick the Pokémon to give.
private struct TradePicker: View {
    let entries: [BankEntry]
    let pick: (BankEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(entries) { entry in
            Button {
                pick(entry)
                dismiss()
            } label: {
                BankEntryRow(entry: entry)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Tu donnes…")
    }
}
