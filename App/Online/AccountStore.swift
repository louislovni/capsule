import Combine
import Foundation

/// A friend, or a friend request either way (a friendships document, id = the two uids in order).
struct Friend: Identifiable, Equatable {
    let id: String
    let uid: String
    let name: String
    let accepted: Bool
    /// The request came from me (it waits for them).
    let mine: Bool
}

/// A trade with a friend that isn't over yet.
struct TradeSummary: Identifiable, Equatable {
    let id: String
    let friendUID: String
    let friendName: String
    let startedByMe: Bool
    let updated: Date
}

/// The player's account: Google sign-in, a profile with a friend code, friends, and the
/// trades going on with them (all in the project's Firestore; see firestore.rules).
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var user: AuthSession.User?
    @Published private(set) var name = ""
    @Published private(set) var code = ""
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var trades: [TradeSummary] = []
    @Published private(set) var busy = false
    @Published var error: String?

    let config = FirebaseConfig.shared
    private(set) var auth: AuthSession?
    private var restored = false

    var isConfigured: Bool { config != nil }

    var database: Firestore? {
        guard let config = config, let auth = auth else { return nil }
        return Firestore(config: config, auth: auth)
    }

    init() {
        if let config = config {
            auth = AuthSession(config: config)
        }
    }

    /// Signed in before: back without the sign-in page.
    func restore() async {
        guard !restored, let auth = auth else { return }
        restored = true
        if let user = await auth.restore() {
            self.user = user
            await refresh()
        }
    }

    func signIn() async {
        guard let auth = auth else {
            error = OnlineError.notConfigured.localizedDescription
            return
        }
        await run {
            let user = try await auth.signIn()
            self.user = user
            try await self.loadProfile(fallbackName: user.name)
            try await self.loadFriendsAndTrades()
        }
    }

    func signOut() {
        auth?.signOut()
        user = nil
        name = ""
        code = ""
        friends = []
        trades = []
    }

    func refresh() async {
        await run {
            try await self.loadProfile(fallbackName: self.user?.name ?? "")
            try await self.loadFriendsAndTrades()
        }
    }

    // MARK: - Profile

    private static let codeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// The profile, made on the first sign-in: a name and a friend code (codes/CODE -> uid).
    private func loadProfile(fallbackName: String) async throws {
        guard let db = database, let uid = user?.uid else { return }
        if let profile = try await db.get("profiles/\(uid)") {
            name = profile["name"].stringValue ?? fallbackName
            code = profile["code"].stringValue ?? ""
            if !code.isEmpty { return }
        }
        var newCode = ""
        for _ in 0..<8 {
            let candidate = String((0..<6).map { _ in Self.codeAlphabet.randomElement()! })
            if try await db.create("codes", id: candidate, fields: ["uid": .string(uid)]) != nil {
                newCode = candidate
                break
            }
        }
        guard !newCode.isEmpty else { throw OnlineError.server("pas de code ami disponible") }
        let displayName = String((name.isEmpty ? fallbackName : name).prefix(40))
        let fields: [String: FieldValue] = ["name": .string(displayName.isEmpty ? "Dresseur" : displayName),
                                            "code": .string(newCode), "updatedAt": .timestamp(Date())]
        if try await db.create("profiles", id: uid, fields: fields) == nil {
            try await db.update("profiles/\(uid)", fields: fields)
        }
        name = fields["name"]?.stringValue ?? ""
        code = newCode
    }

    func rename(_ newName: String) async {
        let trimmed = String(newName.trimmingCharacters(in: .whitespaces).prefix(40))
        guard !trimmed.isEmpty, let uid = user?.uid else { return }
        await run {
            try await self.database?.update("profiles/\(uid)", fields: ["name": .string(trimmed), "updatedAt": .timestamp(Date())])
            self.name = trimmed
        }
    }

    // MARK: - Friends

    static func pairID(_ a: String, _ b: String) -> String {
        a < b ? "\(a)_\(b)" : "\(b)_\(a)"
    }

    private func loadFriendsAndTrades() async throws {
        guard let db = database, let uid = user?.uid else { return }
        let rows = try await db.query("friendships", arrayField: "members", contains: uid)
        friends = rows.compactMap { doc in
            guard let other = doc["members"].listValue.first(where: { $0 != uid }) else { return nil }
            return Friend(id: doc.id, uid: other, name: doc["names"].mapValue[other]?.stringValue ?? "?",
                          accepted: doc["accepted"].boolValue ?? false, mine: doc["requester"].stringValue == uid)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let tradeRows = try await db.query("trades", arrayField: "members", contains: uid)
        var open: [TradeSummary] = []
        for doc in tradeRows {
            guard let other = doc["members"].listValue.first(where: { $0 != uid }) else { continue }
            let cancelled = doc["cancel_\(uid)"].boolValue == true || doc["cancel_\(other)"].boolValue == true
            let doneMine = doc["done_\(uid)"].boolValue == true
            let updated = doc["updatedAt"].dateValue ?? .distantPast
            // Over (or left a week): gone from the list, and the document with it.
            if (cancelled && doneMine) || (doneMine && doc["done_\(other)"].boolValue == true) || updated.timeIntervalSinceNow < -7 * 86400 {
                try? await db.delete("trades/\(doc.id)")
                continue
            }
            if doneMine || doc["cancel_\(uid)"].boolValue == true { continue }
            open.append(TradeSummary(id: doc.id, friendUID: other, friendName: doc["names"].mapValue[other]?.stringValue ?? "?",
                                     startedByMe: doc["starter"].stringValue == uid, updated: updated))
        }
        trades = open.sorted { $0.updated > $1.updated }
    }

    /// Asks the player with this friend code to be friends (or accepts their request).
    func addFriend(code rawCode: String) async {
        let friendCode = rawCode.uppercased().filter { !$0.isWhitespace }
        guard let db = database, let uid = user?.uid else { return }
        await run {
            guard friendCode.count == 6, let entry = try await db.get("codes/\(friendCode)"),
                  let other = entry["uid"].stringValue else {
                throw OnlineError.notFound("Aucun joueur avec le code \(friendCode).")
            }
            guard other != uid else { throw OnlineError.refused("C'est ton propre code.") }
            let pair = Self.pairID(uid, other)
            let otherName = try await db.get("profiles/\(other)")?["name"].stringValue ?? "?"
            let fields: [String: FieldValue] = [
                "members": .strings([uid, other]),
                "names": .map([uid: .string(self.name), other: .string(otherName)]),
                "requester": .string(uid),
                "accepted": .bool(false),
                "createdAt": .timestamp(Date()),
            ]
            if try await db.create("friendships", id: pair, fields: fields) == nil {
                // Already there: their request to me is accepted by mine.
                if let existing = try await db.get("friendships/\(pair)"),
                   existing["requester"].stringValue == other, existing["accepted"].boolValue != true {
                    try await db.update("friendships/\(pair)", fields: ["accepted": .bool(true)])
                }
            }
            try await self.loadFriendsAndTrades()
        }
    }

    func accept(_ friend: Friend) async {
        await run {
            try await self.database?.update("friendships/\(friend.id)", fields: ["accepted": .bool(true)])
            try await self.loadFriendsAndTrades()
        }
    }

    func remove(_ friend: Friend) async {
        await run {
            try await self.database?.delete("friendships/\(friend.id)")
            try await self.loadFriendsAndTrades()
        }
    }

    // MARK: - Trades

    /// Opens a trade with a friend: the trade document both phones then write their side of.
    func startTrade(with friend: Friend) async -> String? {
        guard let db = database, let uid = user?.uid else { return nil }
        if let open = trades.first(where: { $0.friendUID == friend.uid }) {
            return open.id
        }
        var id: String?
        await run {
            let doc = try await db.create("trades", id: nil, fields: [
                "members": .strings([uid, friend.uid]),
                "pair": .string(friend.id),
                "starter": .string(uid),
                "names": .map([uid: .string(self.name), friend.uid: .string(friend.name)]),
                "createdAt": .timestamp(Date()),
                "updatedAt": .timestamp(Date()),
            ])
            id = doc?.id
            try await self.loadFriendsAndTrades()
        }
        return id
    }

    private func run(_ body: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await body()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
