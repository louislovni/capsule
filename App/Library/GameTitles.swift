import SwiftUI

/// A game's name on its cartridge and in play: the compatible games list's name when the ROM is one it knows (by its
/// fingerprint, or an official cart by its code), else its file name tidied up ([CapsuleCard.displayTitle]). The
/// fingerprint is worked out once per file version in the background ([RomIdentity.sha1]); the answer is kept, so the
/// home screen reads it at once next time.
final class GameTitles: ObservableObject {
    static let shared = GameTitles()

    @Published private var known: [String: String] = [:]
    private var asked = Set<String>()
    private let store = UserDefaults.standard

    func title(for game: Game) -> String {
        let key = Self.key(game.romURL)
        if let title = known[key] ?? store.string(forKey: key) {
            return title.isEmpty ? CapsuleCard<EmptyView>.displayTitle(game.name) : title
        }
        if asked.insert(key).inserted {
            Task { await resolve(game, key: key) }
        }
        return CapsuleCard<EmptyView>.displayTitle(game.name)
    }

    private func resolve(_ game: Game, key: String) async {
        let sha1 = await RomIdentity.sha1(of: game.romURL)
        let match = await Task.detached(priority: .utility) { RomIdentity.match(game, sha1: sha1) }.value
        // "" = none known: the file name stays (and isn't looked up again for this version of the file).
        let title = match.map { CapsuleCard<EmptyView>.displayTitle($0.title) } ?? ""
        await MainActor.run {
            store.set(title, forKey: key)
            known[key] = title
        }
    }

    private static func key(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "title|\(url.lastPathComponent)|\(values?.fileSize ?? 0)|\(Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0))"
    }
}
