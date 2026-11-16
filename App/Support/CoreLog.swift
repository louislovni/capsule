import Foundation

/// The cores write what they make of a game to the standard error stream
/// ("pokedaisy: Pokémon Unbound, sha1 … ", "PokeDaisy DS: companion enabled…").
/// The app sends that stream to Documents/PokeDaisy/journal.txt (visible in
/// the Files app), and reads back what a core said about the game it just loaded.
enum CoreLog {
    static let url = Storage.documents
        .appendingPathComponent("PokeDaisy", isDirectory: true)
        .appendingPathComponent("journal.txt")

    /// Starts a fresh journal for this run of the app.
    static func start() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard freopen(url.path, "w", stderr) != nil else { return }
        setvbuf(stderr, nil, _IONBF, 0)
    }

    /// Where the journal ends now: what comes after is the next game's.
    static func mark() -> UInt64 {
        fflush(stderr)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
        return size ?? 0
    }

    /// The lines written since `mark`.
    static func lines(since mark: UInt64) -> [String] {
        fflush(stderr)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: mark)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    /// PokeDaisy's reasons, in French.
    private static let reasons = [
        "Not a version the companion knows": "version que le compagnon ne connaît pas",
        "ROM hacks aren't supported on 3DS yet": "hack dont cette version n'est pas reconnue (PokeDaisy identifie chaque hack par l'empreinte exacte de sa ROM)",
        "This revision isn't supported yet": "révision du jeu pas encore prise en charge",
        "Not a game the 3DS companion knows yet": "jeu que le compagnon ne connaît pas",
        "Not a Game Boy game the companion knows": "jeu Game Boy que le compagnon ne connaît pas",
        "Not a game the companion can read": "jeu sans équipe à lire",
        "Recognised, but its memory layout isn't mapped yet": "jeu reconnu mais pas encore pris en charge",
    ]

    /// What PokeDaisy says about a game it just loaded, in French, or nil when it said nothing.
    static func companionStatus(lines: [String], isDS: Bool) -> (supported: Bool, text: String)? {
        if isDS {
            guard let line = lines.last(where: { $0.contains("PokeDaisy DS: companion") }) else { return nil }
            return line.contains("enabled")
                ? (true, "Compagnon PokeDaisy actif")
                : (false, "PokeDaisy ne connaît pas cette cartouche : le jeu tourne sans son compagnon")
        }
        // "pokedaisy: TITLE, sha1 HEX" then " - REASON" when the companion can't read the game.
        guard let line = lines.last(where: { $0.hasPrefix("pokedaisy: ") }) else { return nil }
        let body = line.dropFirst("pokedaisy: ".count)
        let parts = body.components(separatedBy: ", sha1 ")
        let title = parts.first ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        let reasonParts = rest.components(separatedBy: " - ")
        let sha1 = reasonParts.first ?? ""
        if reasonParts.count > 1 {
            let reason = reasonParts.dropFirst().joined(separator: " - ")
            return (false, "Compagnon PokeDaisy indisponible pour cette ROM (\(title)) : \(reasons[reason] ?? reason). SHA-1 \(sha1)")
        }
        return (true, "PokeDaisy : \(title)")
    }
}
