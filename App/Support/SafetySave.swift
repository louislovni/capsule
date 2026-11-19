import Foundation

/// One spare copy of each game's save, the last resort if the save goes wrong. It's the save as it
/// was when the game was last started, kept only if it opens as a save of its kind (a broken save
/// never replaces a good copy). One save per game otherwise: no save states.
enum SafetySave {
    static let folder = Storage.backups.appendingPathComponent("Secours", isDirectory: true)

    static func url(for game: Game) -> URL {
        folder.appendingPathComponent(game.name + ".sav")
    }

    /// When the game wrote the save the spare copy holds (nil: no copy). The copy keeps the
    /// save's own date.
    static func date(for game: Game) -> Date? {
        let url = url(for: game)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Storage.modificationDate(of: url)
    }

    /// Before the game starts: the save as it is now becomes the spare copy, if it reads.
    static func refresh(_ game: Game) {
        guard game.hasSave, opens(game.saveURL, game: game) else { return }
        let manager = FileManager.default
        let target = url(for: game)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        if let current = try? Data(contentsOf: game.saveURL),
           let kept = try? Data(contentsOf: target), current == kept {
            return
        }
        let temporary = folder.appendingPathComponent(game.name + ".sav.new")
        try? manager.removeItem(at: temporary)
        guard (try? manager.copyItem(at: game.saveURL, to: temporary)) != nil else { return }
        try? manager.removeItem(at: target)
        try? manager.moveItem(at: temporary, to: target)
    }

    /// Puts the spare copy back as the save. The save it replaces is kept as a dated backup.
    static func restore(_ game: Game) throws {
        let spare = url(for: game)
        if game.hasSave {
            try SaveBackup.backUp(game.saveURL)
            try FileManager.default.removeItem(at: game.saveURL)
        }
        try FileManager.default.copyItem(at: spare, to: game.saveURL)
    }

    /// Whether the file reads as a save of the game's kind (its PC boxes open).
    private static func opens(_ url: URL, game: Game) -> Bool {
        if game.isDS {
            return (try? NDSSaveFile(url: url, sourceGame: game.name)) != nil
        }
        if game.romURL.pathExtension.lowercased() == "gba" {
            return (try? SaveFile(url: url)) != nil
        }
        return (try? GBSaveFile(url: url, sourceGame: game.name)) != nil
    }
}
