import Combine
import Foundation

/// A trade with a friend far away: a Firestore document (trades/ID) both phones read every two
/// seconds and write their own fields of (offer_UID: the Pokémon put up, as JSON; confirm_UID:
/// "mine|theirs", the pair agreed to; done_UID / cancel_UID). Each bank swaps once both sides
/// have confirmed the same pair - the nearby trade's rules, through the database.
@MainActor
final class RemoteTrade: ObservableObject {
    enum Phase: Equatable {
        case loading
        case open
        case finished(received: String, given: String)
        case cancelled(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var friendName = ""
    @Published private(set) var myOffer: BankEntry?
    @Published private(set) var theirOffer: BankEntry?
    @Published private(set) var iConfirmed = false
    @Published private(set) var theirConfirm = ""

    let id: String
    private let account: AccountStore
    private let bank: BankStore
    private var polling: Task<Void, Never>?
    private var committed = false
    private var loadedMine = false

    init(id: String, account: AccountStore, bank: BankStore) {
        self.id = id
        self.account = account
        self.bank = bank
    }

    var theyConfirmed: Bool {
        guard let mine = myOffer, let theirs = theirOffer else { return false }
        return theirConfirm == "\(theirs.id.uuidString)|\(mine.id.uuidString)"
    }

    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
    }

    private var path: String { "trades/\(id)" }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func decode(_ json: String?) -> BankEntry? {
        guard let json = json, !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(BankEntry.self, from: data)
    }

    private func poll() async {
        guard let db = account.database, let uid = account.user?.uid else { return }
        switch phase {
        case .finished, .cancelled: return
        default: break
        }
        do {
            guard let doc = try await db.get(path) else {
                if !committed {
                    phase = .cancelled("Cet échange n'existe plus.")
                }
                return
            }
            let other = doc["members"].listValue.first { $0 != uid } ?? ""
            friendName = doc["names"].mapValue[other]?.stringValue ?? "?"

            if !loadedMine {
                // Opened again: my side as I left it.
                loadedMine = true
                let mine = decode(doc["offer_\(uid)"].stringValue)
                let theirs = decode(doc["offer_\(other)"].stringValue)
                if doc["done_\(uid)"].boolValue == true {
                    committed = true
                    phase = .finished(received: theirs?.displayName ?? "Le Pokémon", given: mine?.displayName ?? "le tien")
                    return
                }
                if let mine = mine, !bank.entries.contains(where: { $0.id == mine.id }) {
                    if let theirs = theirs, bank.entries.contains(where: { $0.id == theirs.id }) {
                        // Swapped here before the app could say so: say it now.
                        committed = true
                        try? await db.update(path, fields: ["done_\(uid)": .bool(true), "updatedAt": .timestamp(Date())])
                        phase = .finished(received: theirs.displayName, given: mine.displayName)
                        return
                    }
                } else {
                    myOffer = mine
                    iConfirmed = mine != nil && theirs != nil &&
                        doc["confirm_\(uid)"].stringValue == "\(mine!.id.uuidString)|\(theirs!.id.uuidString)"
                }
            }

            if doc["cancel_\(other)"].boolValue == true && !committed {
                phase = .cancelled("\(friendName) a annulé l'échange.")
                return
            }
            let offer = decode(doc["offer_\(other)"].stringValue)
            if offer?.id != theirOffer?.id {
                theirOffer = offer
                // Their choice changed: my agreement was for the other one.
                if iConfirmed {
                    iConfirmed = false
                    try? await db.update(path, fields: ["confirm_\(uid)": .string(""), "updatedAt": .timestamp(Date())])
                }
            }
            theirConfirm = doc["confirm_\(other)"].stringValue ?? ""
            if phase == .loading {
                phase = .open
            }
            await commitIfReady()
        } catch {
            if phase == .loading {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func offer(_ entry: BankEntry?) async {
        guard let db = account.database, let uid = account.user?.uid else { return }
        myOffer = entry
        iConfirmed = false
        var json = ""
        if let entry = entry, let data = try? Self.encoder.encode(entry) {
            json = String(data: data, encoding: .utf8) ?? ""
        }
        do {
            try await db.update(path, fields: ["offer_\(uid)": .string(json), "confirm_\(uid)": .string(""),
                                               "updatedAt": .timestamp(Date())])
        } catch {
            account.error = error.localizedDescription
        }
    }

    func confirm() async {
        guard let db = account.database, let uid = account.user?.uid,
              let mine = myOffer, let theirs = theirOffer, !committed else { return }
        iConfirmed = true
        do {
            try await db.update(path, fields: ["confirm_\(uid)": .string("\(mine.id.uuidString)|\(theirs.id.uuidString)"),
                                               "updatedAt": .timestamp(Date())])
            await commitIfReady()
        } catch {
            iConfirmed = false
            account.error = error.localizedDescription
        }
    }

    func cancel() async {
        guard let db = account.database, let uid = account.user?.uid, !committed else { return }
        try? await db.update(path, fields: ["cancel_\(uid)": .bool(true), "updatedAt": .timestamp(Date())])
        phase = .cancelled("Échange annulé.")
    }

    private func commitIfReady() async {
        guard !committed, iConfirmed, theyConfirmed, let mine = myOffer, let theirs = theirOffer,
              let db = account.database, let uid = account.user?.uid else { return }
        committed = true
        do {
            let received = try bank.trade(giving: mine, receiving: theirs)
            phase = .finished(received: received.displayName, given: mine.displayName)
            try? await db.update(path, fields: ["done_\(uid)": .bool(true), "updatedAt": .timestamp(Date())])
        } catch {
            committed = false
            phase = .failed(error.localizedDescription)
        }
    }
}
