import Combine
import CryptoKit
import Foundation
import UIKit

/// The saves (Documents/Saves) and the bank, kept on the player's account, so another device
/// signed in to it carries on the same games. In Firestore, under users/UID (only that user
/// reads or writes there): files/ID, a file's description (name, SHA-256, size, how many
/// pieces), and chunks/ID_N, its bytes in base64 pieces small enough for a document.
///
/// Each file: the hash the last sync left on both sides (Documents/Saves/.cloud.json) says
/// which side changed since. One side only: it goes to the other. Both: the newer stays and
/// the other is kept in Backups. The bank is merged instead (BankStore.mergeCloud).
@MainActor
final class CloudSync: ObservableObject {
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastReport = ""
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "cloudSyncEnabled"
    private static let bankName = "#banque"
    private static let chunkSize = 600_000   // base64 characters per piece (documents hold 1 MiB)

    private var account: AccountStore?
    private var bank: BankStore?
    private let manifestURL = Storage.saves.appendingPathComponent(".cloud.json")

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        lastSync = UserDefaults.standard.object(forKey: "cloudLastSync") as? Date
    }

    func attach(account: AccountStore, bank: BankStore) {
        self.account = account
        self.bank = bank
    }

    // MARK: - Manifest: the hash each file had at the last sync

    private func loadManifest() -> [String: String] {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return manifest
    }

    private func saveManifest(_ manifest: [String: String]) {
        try? FileManager.default.createDirectory(at: Storage.saves, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The save's hash without mGBA's 16-byte clock footer (a save chip is a multiple of 512 bytes; the footer is
    /// what's past the last whole 512). It moves with the clock alone, and the PC's core writes none: two saves with
    /// the same core are the same save.
    private static func coreHash(_ data: Data) -> String {
        let n = data.count - data.count % 512
        return n == 0 ? hash(data) : hash(data.prefix(n))
    }

    /// When a save was written here (conflicts go by it, not by when it was uploaded).
    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
    }

    /// A document ID for a file name (any characters in, letters and digits out).
    private static func fileID(_ name: String) -> String {
        String(hash(Data(name.utf8)).prefix(32))
    }

    // MARK: - Sync

    /// Syncs now, unless off, signed out or already at it. `playing`: a game open, whose save is left alone.
    func sync(skipping playing: String? = nil) async {
        guard enabled, !syncing, let account = account, let bank = bank,
              let db = account.database, let uid = account.user?.uid else { return }
        syncing = true
        let task = UIApplication.shared.beginBackgroundTask(withName: "cloud-sync")
        defer {
            syncing = false
            UIApplication.shared.endBackgroundTask(task)
        }
        do {
            var report = SyncReport()
            let root = "users/\(uid)"
            var cloud: [String: FSDocument] = [:]
            for doc in try await db.list("\(root)/files") {
                if let name = doc["name"].stringValue {
                    cloud[name] = doc
                }
            }
            var manifest = loadManifest()

            try await syncBank(bank: bank, db: db, root: root, cloud: cloud[Self.bankName], manifest: &manifest, report: &report)

            let local = localSaves()
            let names = Set(local.keys).union(cloud.keys.filter { $0 != Self.bankName })
            for name in names.sorted() {
                if let playing = playing, name == playing + ".sav" { continue }
                let url = Storage.saves.appendingPathComponent(name)
                let localData = local[name]
                let localHash = localData.map(Self.hash)
                let cloudHash = cloud[name]?["hash"].stringValue
                let synced = manifest[name]
                let syncedCore = manifest["core:" + name]
                let localCore = localData.map(Self.coreHash)
                let cloudCore = cloud[name]?["core"].stringValue
                if localHash == cloudHash || (localCore != nil && localCore == cloudCore) {
                    // The same save (maybe with another clock footer): nothing to send.
                    if let hash = localHash { manifest[name] = hash; manifest["core:" + name] = localCore }
                    continue
                }
                // Changed since the last sync: by the save's core when the last sync noted it, else by the whole file.
                var localChanged = localHash != nil && localHash != synced
                if localChanged, let syncedCore = syncedCore { localChanged = localCore != syncedCore }
                var cloudChanged = cloudHash != nil && cloudHash != synced
                if cloudChanged, let syncedCore = syncedCore, let cloudCore = cloudCore { cloudChanged = cloudCore != syncedCore }
                if let data = localData, let hash = localHash, cloudHash == nil || (localChanged && !cloudChanged) {
                    try await upload(db: db, root: root, name: name, data: data, hash: hash, modified: Self.modified(url))
                    manifest[name] = hash
                    manifest["core:" + name] = localCore
                    report.sent += 1
                } else if let doc = cloud[name], let hash = cloudHash, localData == nil || (cloudChanged && !localChanged) {
                    let theirs = try await download(db: db, root: root, doc: doc)
                    try write(theirs, to: url, keepingOld: localData != nil)
                    manifest[name] = hash
                    manifest["core:" + name] = Self.coreHash(theirs)
                    report.received += 1
                } else if let data = localData, let hash = localHash, let doc = cloud[name], let theirHash = cloudHash {
                    // Changed on both sides: the save made last goes on (when each was written, not uploaded), the
                    // other is kept.
                    let localDate = Self.modified(url)
                    let cloudDate = doc["modifiedAt"].dateValue ?? doc["updatedAt"].dateValue ?? .distantPast
                    let theirs = try await download(db: db, root: root, doc: doc)
                    if localDate >= cloudDate {
                        try backup(theirs, name: name, tag: "cloud")
                        try await upload(db: db, root: root, name: name, data: data, hash: hash, modified: localDate)
                        manifest[name] = hash
                        manifest["core:" + name] = localCore
                    } else {
                        try write(theirs, to: url, keepingOld: true)
                        manifest[name] = theirHash
                        manifest["core:" + name] = Self.coreHash(theirs)
                    }
                    report.conflicts += 1
                }
            }
            saveManifest(manifest)
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: "cloudLastSync")
            lastReport = report.text
        } catch {
            lastReport = "Échec : \(error.localizedDescription)"
        }
    }

    private struct SyncReport {
        var sent = 0
        var received = 0
        var conflicts = 0
        var bank = ""

        var text: String {
            var parts: [String] = []
            if sent > 0 { parts.append("\(sent) sauvegarde\(sent > 1 ? "s" : "") envoyée\(sent > 1 ? "s" : "")") }
            if received > 0 { parts.append("\(received) récupérée\(received > 1 ? "s" : "")") }
            if conflicts > 0 { parts.append("\(conflicts) en double (l'ancienne copie est dans Backups)") }
            if !bank.isEmpty { parts.append(bank) }
            return parts.isEmpty ? "Tout est à jour." : parts.joined(separator: ", ") + "."
        }
    }

    private func syncBank(bank: BankStore, db: Firestore, root: String, cloud: FSDocument?, manifest: inout [String: String],
                          report: inout SyncReport) async throws {
        if let doc = cloud, let cloudHash = doc["hash"].stringValue, cloudHash != manifest[Self.bankName] {
            let before = bank.entries.count
            try bank.mergeCloud(try await download(db: db, root: root, doc: doc))
            if bank.entries.count != before {
                report.bank = "banque fusionnée"
            }
            manifest[Self.bankName] = cloudHash
        }
        let payload = try bank.cloudPayload()
        let hash = Self.hash(payload)
        if hash != cloud?["hash"].stringValue && !(bank.entries.isEmpty && bank.removedIDs.isEmpty && cloud == nil) {
            try await upload(db: db, root: root, name: Self.bankName, data: payload, hash: hash, modified: Date())
            if report.bank.isEmpty {
                report.bank = "banque envoyée"
            }
        }
        manifest[Self.bankName] = hash
    }

    private func localSaves() -> [String: Data] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Storage.saves, includingPropertiesForKeys: nil)) ?? []
        var saves: [String: Data] = [:]
        for url in files where !url.lastPathComponent.hasPrefix(".") && url.pathExtension.lowercased() == "sav" {
            if let data = try? Data(contentsOf: url), !data.isEmpty, data.count < 4_000_000 {
                saves[url.lastPathComponent] = data
            }
        }
        return saves
    }

    // MARK: - Files in pieces

    private func upload(db: Firestore, root: String, name: String, data: Data, hash: String, modified: Date) async throws {
        let id = Self.fileID(name)
        let text = data.base64EncodedString()
        var pieces: [Substring] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: Self.chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            pieces.append(text[start..<end])
            start = end
        }
        if pieces.isEmpty {
            pieces = [""]
        }
        // The pieces first, under this version's hash: the description, written last, points at them.
        let version = String(hash.prefix(12))
        for (index, piece) in pieces.enumerated() {
            try await db.set("\(root)/chunks/\(id)_\(version)_\(index)", fields: ["data": .string(String(piece))])
        }
        let old = try await db.get("\(root)/files/\(id)")
        try await db.set("\(root)/files/\(id)", fields: [
            "name": .string(name),
            "hash": .string(hash),
            "core": .string(Self.coreHash(data)),
            "modifiedAt": .timestamp(modified),
            "size": .int(data.count),
            "chunks": .int(pieces.count),
            "version": .string(version),
            "updatedAt": .timestamp(Date()),
            "device": .string(UIDevice.current.name),
        ])
        // The previous version's pieces go.
        if let old = old, let oldVersion = old["version"].stringValue, oldVersion != version,
           case .int(let count) = old["chunks"] {
            for index in 0..<count {
                try? await db.delete("\(root)/chunks/\(id)_\(oldVersion)_\(index)")
            }
        }
    }

    private func download(db: Firestore, root: String, doc: FSDocument) async throws -> Data {
        guard let version = doc["version"].stringValue, case .int(let count) = doc["chunks"],
              let hash = doc["hash"].stringValue else {
            throw OnlineError.server("fichier incomplet dans le cloud")
        }
        let id = doc.id
        var text = ""
        for index in 0..<count {
            guard let piece = try await db.get("\(root)/chunks/\(id)_\(version)_\(index)")?["data"].stringValue else {
                throw OnlineError.server("morceau manquant dans le cloud")
            }
            text += piece
        }
        guard let data = Data(base64Encoded: text), Self.hash(data) == hash else {
            throw OnlineError.server("fichier abîmé dans le cloud")
        }
        return data
    }

    private func write(_ data: Data, to url: URL, keepingOld: Bool) throws {
        if keepingOld, let old = try? Data(contentsOf: url) {
            try backup(old, name: url.lastPathComponent, tag: "avant-cloud")
        }
        try FileManager.default.createDirectory(at: Storage.saves, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func backup(_ data: Data, name: String, tag: String) throws {
        let folder = Storage.backups.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        try data.write(to: folder.appendingPathComponent("\(base)-\(tag)-\(formatter.string(from: Date())).\(ext)"), options: .atomic)
    }
}
