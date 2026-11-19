import SwiftUI

/// Amis et échanges en ligne: Google sign-in, the friend code, friends, trades going on.
struct AccountView: View {
    @ObservedObject var account: AccountStore
    @ObservedObject var bank: BankStore
    @ObservedObject var cloud: CloudSync
    @State private var friendCode = ""
    @State private var editingName = false
    @State private var newName = ""
    @State private var openTradeID: String?
    @State private var showTrade = false

    var body: some View {
        List {
            if !account.isConfigured {
                Section {
                    Text("Les comptes en ligne ne sont pas encore configurés dans cette version de l'app.")
                        .foregroundStyle(.secondary)
                }
            } else if account.user == nil {
                signedOut
            } else {
                signedIn
            }
        }
        .navigationTitle("Amis")
        .capsuleScreen()
        .overlay {
            if account.busy {
                ProgressView()
            }
        }
        .task {
            await account.restore()
        }
        .refreshable {
            await account.refresh()
        }
        .navigationDestination(isPresented: $showTrade) {
            if let id = openTradeID {
                RemoteTradeView(trade: RemoteTrade(id: id, account: account, bank: bank), bank: bank)
            }
        }
        .alert("Erreur", isPresented: Binding(get: { account.error != nil }, set: { if !$0 { account.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(account.error ?? "")
        }
        .alert("Ton nom", isPresented: $editingName) {
            TextField("Nom", text: $newName)
            Button("Enregistrer") {
                Task { await account.rename(newName) }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le nom que tes amis voient.")
        }
    }

    private var signedOut: some View {
        Section {
            Button {
                Task {
                    await account.signIn()
                    await cloud.sync()
                }
            } label: {
                Label("Se connecter avec Google", systemImage: "person.crop.circle.badge.plus")
            }
            .disabled(account.busy)
        } footer: {
            Text("Ton compte sert à ajouter des amis avec un code et à échanger des Pokémon de ta banque à distance. Seuls ton prénom et ton code ami sont visibles des autres joueurs.")
        }
    }

    @ViewBuilder
    private var signedIn: some View {
        Section {
            HStack {
                Text(account.name)
                    .font(.headline)
                Spacer()
                Button("Modifier") {
                    newName = account.name
                    editingName = true
                }
                .font(.subheadline)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ton code ami")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(account.code.isEmpty ? "…" : account.code)
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .textSelection(.enabled)
                }
                Spacer()
                if !account.code.isEmpty {
                    ShareLink(item: "Ajoute-moi dans Capsule : mon code ami est \(account.code)") {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        } header: {
            Text("Ton profil")
        }

        Section {
            Toggle("Sauvegarde dans le cloud", isOn: $cloud.enabled)
            if cloud.enabled {
                Button {
                    Task { await cloud.sync() }
                } label: {
                    HStack {
                        Label("Synchroniser maintenant", systemImage: "arrow.triangle.2.circlepath.icloud")
                        Spacer()
                        if cloud.syncing {
                            ProgressView()
                        }
                    }
                }
                .disabled(cloud.syncing)
            }
        } header: {
            Text("Cloud")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Les sauvegardes des jeux (.sav) et la banque vont sur ton compte, et reviennent sur tout appareil connecté avec lui. Les états instantanés restent sur l'iPhone.")
                if let date = cloud.lastSync {
                    Text("Dernière synchro : \(date.formatted(date: .abbreviated, time: .shortened)). \(cloud.lastReport)")
                }
            }
        }

        Section {
            HStack {
                TextField("Code ami (6 caractères)", text: $friendCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Ajouter") {
                    let code = friendCode
                    friendCode = ""
                    Task { await account.addFriend(code: code) }
                }
                .disabled(friendCode.filter { !$0.isWhitespace }.count != 6 || account.busy)
            }
        } header: {
            Text("Ajouter un ami")
        }

        let received = account.friends.filter { !$0.accepted && !$0.mine }
        if !received.isEmpty {
            Section("Demandes reçues") {
                ForEach(received) { friend in
                    HStack {
                        Text(friend.name)
                        Spacer()
                        Button("Accepter") {
                            Task { await account.accept(friend) }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Refuser", role: .destructive) {
                            Task { await account.remove(friend) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }

        if !account.trades.isEmpty {
            Section("Échanges en cours") {
                ForEach(account.trades) { trade in
                    Button {
                        openTradeID = trade.id
                        showTrade = true
                    } label: {
                        Label("Avec \(trade.friendName)", systemImage: "arrow.left.arrow.right")
                    }
                }
            }
        }

        Section {
            let accepted = account.friends.filter { $0.accepted }
            if accepted.isEmpty {
                Text("Pas encore d'amis : partage ton code, ou entre celui d'un ami.")
                    .foregroundStyle(.secondary)
            }
            ForEach(accepted) { friend in
                HStack {
                    Label(friend.name, systemImage: "person")
                    Spacer()
                    Button("Échanger") {
                        Task {
                            if let id = await account.startTrade(with: friend) {
                                openTradeID = id
                                showTrade = true
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .swipeActions {
                    Button("Retirer", role: .destructive) {
                        Task { await account.remove(friend) }
                    }
                }
            }
        } header: {
            Text("Amis")
        }

        let sent = account.friends.filter { !$0.accepted && $0.mine }
        if !sent.isEmpty {
            Section("Demandes envoyées") {
                ForEach(sent) { friend in
                    HStack {
                        Text(friend.name)
                        Spacer()
                        Text("En attente")
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Annuler", role: .destructive) {
                            Task { await account.remove(friend) }
                        }
                    }
                }
            }
        }

        Section {
            Button("Se déconnecter", role: .destructive) {
                account.signOut()
            }
        } footer: {
            if let email = account.user?.email, !email.isEmpty {
                Text("Connecté avec \(email). Tire vers le bas pour actualiser.")
            }
        }
    }
}

/// A trade with a friend: the same table as the nearby one, through the database.
struct RemoteTradeView: View {
    @StateObject var trade: RemoteTrade
    @ObservedObject var bank: BankStore

    init(trade: RemoteTrade, bank: BankStore) {
        _trade = StateObject(wrappedValue: trade)
        self.bank = bank
    }

    var body: some View {
        content
            .navigationTitle(trade.friendName.isEmpty ? "Échange" : "Échange avec \(trade.friendName)")
            .capsuleScreen()
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { trade.start() }
            .onDisappear { trade.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch trade.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .open:
            table
        case .finished(let received, let given):
            message(icon: "checkmark.circle.fill", color: .green, title: "Échange terminé !",
                    text: "\(received) a rejoint ta banque, à la place de \(given).")
        case .cancelled(let reason):
            message(icon: "xmark.circle", color: .secondary, title: "Échange annulé", text: reason)
        case .failed(let reason):
            message(icon: "exclamationmark.triangle", color: .orange, title: "Problème", text: reason)
        }
    }

    private func message(icon: String, color: Color, title: String, text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(color)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        List {
            Section {
                NavigationLink {
                    RemoteTradePicker(entries: bank.entries) { entry in
                        Task { await trade.offer(entry) }
                    }
                } label: {
                    if let mine = trade.myOffer {
                        BankEntryRow(entry: mine)
                    } else {
                        Label("Choisir un Pokémon", systemImage: "plus.circle")
                    }
                }
                .disabled(bank.entries.isEmpty)
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
                    Text("\(trade.friendName) n'a pas encore choisi.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Tu reçois")
            }

            Section {
                Button {
                    Task { await trade.confirm() }
                } label: {
                    Text(trade.iConfirmed ? "Validé" : "Valider l'échange")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trade.myOffer == nil || trade.theirOffer == nil || trade.iConfirmed)
                .listRowBackground(Color.clear)
                Button("Annuler l'échange", role: .destructive) {
                    Task { await trade.cancel() }
                }
                .frame(maxWidth: .infinity)
            } footer: {
                Text(status)
            }
        }
    }

    private var status: String {
        switch (trade.iConfirmed, trade.theyConfirmed) {
        case (true, false): return "En attente de \(trade.friendName)… Tu peux quitter cet écran : l'échange reste dans « Échanges en cours »."
        case (false, true): return "\(trade.friendName) a validé : à toi."
        default: return "L'échange se fait quand vous avez validé tous les deux. Changer de Pokémon annule les validations."
        }
    }
}

private struct RemoteTradePicker: View {
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
        .capsuleScreen()
    }
}
