import Foundation

/// The game's own saves, kept as they were made: each time the player saves in the game, a copy goes here, and the
/// library can put any of the last ones back (a legendary knocked out by mistake, then saved over). Not save states:
/// only saves the player made in the game.
enum SaveHistory {
    struct Point: Identifiable {
        let url: URL
        let date: Date
        var id: URL { url }
    }

    static let keep = 20
    /// Writes closer together than this are one save (a game writes its save over a few frames).
    private static let sameSave: TimeInterval = 20

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static func folder(for game: Game) -> URL {
        Storage.backups.appendingPathComponent("Historique", isDirectory: true)
            .appendingPathComponent(game.name, isDirectory: true)
    }

    /// The save points, newest first.
    static func points(for game: Game) -> [Point] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(for: game), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "sav" }.compactMap { url in
            formatter.date(from: url.deletingPathExtension().lastPathComponent).map { Point(url: url, date: $0) }
        }
        .sorted { $0.date > $1.date }
    }

    /// The save as it is now becomes the newest point (replacing one from a few seconds ago: the same save).
    static func record(_ game: Game, at date: Date = Date()) {
        guard game.hasSave else { return }
        let manager = FileManager.default
        let directory = folder(for: game)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = points(for: game)
        if let newest = existing.first {
            if date.timeIntervalSince(newest.date) < sameSave {
                try? manager.removeItem(at: newest.url)
            } else if let now = try? Data(contentsOf: game.saveURL), let kept = try? Data(contentsOf: newest.url), now == kept {
                return
            }
        }
        let target = directory.appendingPathComponent(formatter.string(from: date) + ".sav")
        try? manager.removeItem(at: target)
        try? manager.copyItem(at: game.saveURL, to: target)
        for old in points(for: game).dropFirst(keep) {
            try? manager.removeItem(at: old.url)
        }
    }

    /// As a game starts: its save as it is, if it isn't the newest point already (the first time, or a save written
    /// as the game closed).
    static func start(_ game: Game) {
        guard let date = Storage.modificationDate(of: game.saveURL) else { return }
        if let newest = points(for: game).first, newest.date >= date.addingTimeInterval(-1) {
            return
        }
        record(game, at: date)
    }

    /// Puts a point back as the save. The save it replaces stays in the dated backups.
    static func restore(_ point: Point, for game: Game) throws {
        if game.hasSave {
            try SaveBackup.backUp(game.saveURL)
            try FileManager.default.removeItem(at: game.saveURL)
        }
        try FileManager.default.copyItem(at: point.url, to: game.saveURL)
    }
}
