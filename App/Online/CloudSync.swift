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
    /// While a game runs: its save, just written in the game, goes up if it changed here alone (nothing comes down
    /// over a save in use, no conflict is settled: the sync when the game closes does that).
    /// Posted (object: the save's file name) when a game in play has written its save.
    static let saveWritten = Notification.Name("CapsuleSaveWritten")

    func push(_ file: String) async {
        await sync(pushing: file)
    }

    func sync(skipping playing: String? = nil, pushing pushOnly: String? = nil) async {
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

            if pushOnly == nil {
                try await syncBank(bank: bank, db: db, root: root, cloud: cloud[Self.bankName], manifest: &manifest, report: &report)
            }

            // Saves go by their game: "rom:" + the ROM's CRC32, the same on every device that has that ROM whatever
            // its file is called (the PC launcher's cloud.go and Android's CapsuleCloud.kt do the same). A save
            // without its ROM here keeps its file name, unless a game's cloud file says it's that game's ("file").
            let byFile = Self.romKeys()      // a save's file name -> its game's key
            var games: [String: FSDocument] = [:]
            var gameOfFile: [String: String] = [:]
            var legacy: [FSDocument] = []
            for (name, doc) in cloud where name != Self.bankName {
                if name.hasPrefix("rom:") {
                    games[name] = doc
                    if let file = doc["file"].stringValue, !file.isEmpty { gameOfFile[file] = name }
                } else {
                    legacy.append(doc)
                }
            }
            var local: [String: Data] = [:]
            var fileOf: [String: String] = [:]
            for (file, data) in localSaves() {
                let key = byFile[file] ?? gameOfFile[file] ?? file
                local[key] = data
                fileOf[key] = file
            }
            // A save uploaded by its file name (before game keys, or from a device without the game): its game's
            // file when it's a game's here (the newer of the two if both exist; the old one goes once synced).
            var moved: [String: FSDocument] = [:]
            for doc in legacy {
                guard let name = doc["name"].stringValue else { continue }
                guard let key = byFile[name] ?? gameOfFile[name] else {
                    games[name] = doc
                    continue
                }
                if let current = games[key], Self.updated(current) >= Self.updated(doc) {} else { games[key] = doc }
                moved[key] = doc
                if fileOf[key] == nil { fileOf[key] = name }
                if manifest[key] == nil, let old = manifest[name] {   // the last sync's by its old name
                    manifest[key] = old
                    manifest["core:" + key] = manifest["core:" + name]
                }
            }
            for (file, key) in byFile where fileOf[key] == nil { fileOf[key] = file }
            for (key, doc) in games where fileOf[key] == nil {
                fileOf[key] = doc["file"].stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? key
            }
            let names = Set(local.keys).union(games.keys)
            for name in names.sorted() {
                let file = fileOf[name] ?? name
                if let playing = playing, file == playing + ".sav" { continue }
                if let pushOnly = pushOnly, file != pushOnly { continue }
                let url = Storage.saves.appendingPathComponent(file)
                let localData = local[name]
                let localHash = localData.map(Self.hash)
                let cloudHash = games[name]?["hash"].stringValue
                let synced = manifest[name]
                let syncedCore = manifest["core:" + name]
                let localCore = localData.map(Self.coreHash)
                let cloudCore = games[name]?["core"].stringValue
                let same = localHash == cloudHash || (localCore != nil && localCore == cloudCore)
                if same, let hash = localHash {
                    // The same save (maybe with another clock footer): nothing to send.
                    manifest[name] = hash
                    manifest["core:" + name] = localCore
                }
                // Changed since the last sync: by the save's core when the last sync noted it, else by the whole file.
                var localChanged = localHash != nil && localHash != synced
                if localChanged, let syncedCore = syncedCore { localChanged = localCore != syncedCore }
                var cloudChanged = cloudHash != nil && cloudHash != synced
                if cloudChanged, let syncedCore = syncedCore, let cloudCore = cloudCore { cloudChanged = cloudCore != syncedCore }
                let goesUp = localData != nil && (cloudHash == nil || (localChanged && !cloudChanged))
                if same || (pushOnly != nil && !goesUp) {
                } else if let data = localData, let hash = localHash, cloudHash == nil || (localChanged && !cloudChanged) {
                    try await upload(db: db, root: root, name: name, file: file, data: data, hash: hash, modified: Self.modified(url))
                    manifest[name] = hash
                    manifest["core:" + name] = localCore
                    report.sent += 1
                } else if let doc = games[name], let hash = cloudHash, localData == nil || (cloudChanged && !localChanged) {
                    let theirs = try await download(db: db, root: root, doc: doc)
                    try write(theirs, to: url, keepingOld: localData != nil)
                    manifest[name] = hash
                    manifest["core:" + name] = Self.coreHash(theirs)
                    report.received += 1
                } else if let data = localData, let hash = localHash, let doc = games[name], let theirHash = cloudHash {
                    // Changed on both sides: the save made last goes on (when each was written, not uploaded), the
                    // other is kept.
                    let localDate = Self.modified(url)
                    let cloudDate = doc["modifiedAt"].dateValue ?? doc["updatedAt"].dateValue ?? .distantPast
                    let theirs = try await download(db: db, root: root, doc: doc)
                    if localDate >= cloudDate {
                        try backup(theirs, name: file, tag: "cloud")
                        try await upload(db: db, root: root, name: name, file: file, data: data, hash: hash, modified: localDate)
                        manifest[name] = hash
                        manifest["core:" + name] = localCore
                    } else {
                        try write(theirs, to: url, keepingOld: true)
                        manifest[name] = theirHash
                        manifest["core:" + name] = Self.coreHash(theirs)
                    }
                    report.conflicts += 1
                }
                // The old name-keyed copy, now under its game's key: the save as it stands goes up under the key
                // (when the old copy was the cloud's only one), then the old copy goes.
                if let old = moved[name], pushOnly == nil {
                    if games[name]?.id == old.id {
                        let current = try Data(contentsOf: url)
                        let hash = Self.hash(current)
                        try await upload(db: db, root: root, name: name, file: file, data: current, hash: hash, modified: Self.modified(url))
                        manifest[name] = hash
                        manifest["core:" + name] = Self.coreHash(current)
                    }
                    try await remove(db: db, root: root, doc: old)
                }
            }
            if pushOnly == nil {
                await syncHistory(db: db, root: root, fileOf: fileOf, manifest: &manifest)
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

    /// [file]: the save's file name here (the cloud file's "file": a device without the game names it so).
    private func upload(db: Firestore, root: String, name: String, file: String = "", data: Data, hash: String,
                        modified: Date) async throws {
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
            "file": .string(file),
            "hash": .string(hash),
            "core": .string(Self.coreHash(data)),
            "modifiedAt": .timestamp(modified),
            "size": .int(data.count),
            "chunks": .int(pieces.count),
            "version": .string(version),
            "updatedAt": .timestamp(Date()),
            "device": .string(UIDevice.current.name),
        ])
        // The version replaced goes into the game's cloud history (its pieces kept), for every device's history
        // ([syncHistory]); one that can't be kept is deleted as before.
        if let old = old, let oldVersion = old["version"].stringValue, oldVersion != version,
           case .int(let count) = old["chunks"] {
            guard name != Self.bankName else {   // the bank keeps no history: its old pieces go
                for index in 0..<count { try? await db.delete("\(root)/chunks/\(id)_\(oldVersion)_\(index)") }
                return
            }
            var entry = old.fields
            entry["fileId"] = .string(id)
            do {
                try await db.set("\(root)/history/\(id)_\(oldVersion)", fields: entry)
            } catch {
                for index in 0..<count {
                    try? await db.delete("\(root)/chunks/\(id)_\(oldVersion)_\(index)")
                }
            }
        }
    }

    /// The versions a game's cloud history keeps (as SaveHistory here: 20).
    private static let historyKeep = 20

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// The cloud's history for the games here (older versions of their saves, from any device) comes down into
    /// SaveHistory's folder (by when each was saved), each once; one already here (the same core as a save point or
    /// the save) is skipped. Past [historyKeep] a game's oldest go. The PC launcher's and Android's do the same.
    private func syncHistory(db: Firestore, root: String, fileOf: [String: String], manifest: inout [String: String]) async {
        guard let entries = try? await db.list("\(root)/history") else { return }
        let byKey = Dictionary(grouping: entries) { $0["name"].stringValue ?? "" }
        let date: (FSDocument) -> Date = { $0["modifiedAt"].dateValue ?? $0["updatedAt"].dateValue ?? .distantPast }
        for (key, all) in byKey {
            let list = all.sorted { date($0) > date($1) }
            for doc in list.dropFirst(Self.historyKeep) {
                if let version = doc["version"].stringValue, let fileId = doc["fileId"].stringValue, case .int(let count) = doc["chunks"] {
                    for index in 0..<count { try? await db.delete("\(root)/chunks/\(fileId)_\(version)_\(index)") }
                }
                try? await db.delete("\(root)/history/\(doc.id)")
            }
            guard let file = fileOf[key] else { continue }
            let stem = (file as NSString).deletingPathExtension
            let folder = Storage.backups.appendingPathComponent("Historique", isDirectory: true)
                .appendingPathComponent(stem, isDirectory: true)
            var have: Set<String>?   // the cores here: read once a game has something new to look at
            for doc in list.prefix(Self.historyKeep) where manifest["history:" + doc.id] == nil {
                if have == nil {
                    var cores = Set<String>()
                    if let data = try? Data(contentsOf: Storage.saves.appendingPathComponent(file)) { cores.insert(Self.coreHash(data)) }
                    for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                        if let data = try? Data(contentsOf: url) { cores.insert(Self.coreHash(data)) }
                    }
                    have = cores
                }
                if let core = doc["core"].stringValue, have?.contains(core) == true {
                    manifest["history:" + doc.id] = "1"
                    continue
                }
                guard let fileId = doc["fileId"].stringValue,
                      let data = try? await download(db: db, root: root, doc: doc, id: fileId) else { continue }
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(Self.stampFormatter.string(from: date(doc)) + ".sav")
                if !FileManager.default.fileExists(atPath: target.path) {
                    guard (try? data.write(to: target, options: .atomic)) != nil else { continue }
                }
                have?.insert(Self.coreHash(data))
                manifest["history:" + doc.id] = "1"
            }
        }
    }

    /// A cloud file and its pieces (an old name-keyed copy, once moved to its game's key).
    private func remove(db: Firestore, root: String, doc: FSDocument) async throws {
        if let version = doc["version"].stringValue, case .int(let count) = doc["chunks"] {
            for index in 0..<count { try? await db.delete("\(root)/chunks/\(doc.id)_\(version)_\(index)") }
        }
        try await db.delete("\(root)/files/\(doc.id)")
    }

    private static func updated(_ doc: FSDocument) -> Date { doc["updatedAt"].dateValue ?? .distantPast }

    /// A save's file name -> its game's key ("rom:" + CRC32), for the ROMs here; each CRC kept by name, size and date
    /// (UserDefaults), so a ROM is read once. The same ROM twice: the first file's save is the game's.
    private static func romKeys() -> [String: String] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: Storage.roms, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [])
            .filter { Game.romExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var cache = UserDefaults.standard.dictionary(forKey: "romCRCs") as? [String: String] ?? [:]
        var keys: [String: String] = [:]
        var taken = Set<String>()
        for url in files {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let stamp = "\(url.lastPathComponent)|\(values?.fileSize ?? 0)|\(Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0))"
            var crc = cache[stamp]
            if crc == nil, let data = try? Data(contentsOf: url, options: .alwaysMapped) {
                let value = data.withUnsafeBytes { pk_crc32($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
                crc = String(format: "%08X", value)
                cache[stamp] = crc
            }
            guard let crc else { continue }
            let key = "rom:" + crc
            guard taken.insert(key).inserted else { continue }
            keys[url.deletingPathExtension().lastPathComponent + ".sav"] = key
        }
        UserDefaults.standard.set(cache, forKey: "romCRCs")
        return keys
    }

    /// [id]: the cloud file the pieces belong to (a history entry's "fileId"; a file's own id by default).
    private func download(db: Firestore, root: String, doc: FSDocument, id fileId: String? = nil) async throws -> Data {
        guard let version = doc["version"].stringValue, case .int(let count) = doc["chunks"],
              let hash = doc["hash"].stringValue else {
            throw OnlineError.server("fichier incomplet dans le cloud")
        }
        let id = fileId ?? doc.id
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
