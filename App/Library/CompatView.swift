import CryptoKit
import SwiftUI

/// The games Capsule knows (compat.json, from tools/gen_compat.py): official games and ROM hacks, and for each one
/// whether PokeDaisy's companion and the bank work with it. "Tes jeux" checks the player's own files against it.
struct CompatGame: Decodable, Identifiable {
    let title: String
    let console: String
    let kind: String
    let version: String?
    let code: String?
    let revisions: [Int]?
    let sha1: [String]
    /// Capsule's companion on iPhone (and PC: the same cores).
    let companion: Bool
    /// PokeDaisy's own companion: the PokeDaisy app, and Capsule for Android, which is built from it.
    let pokedaisy: Bool
    let bank: String
    let unverified: Bool?
    let note: String?
    /// A hack: the ROM its patch goes on.
    let base: Base?

    struct Base: Decodable {
        /// GBA / DS: the cart's code and, when it matters, its revision.
        let code: String?
        let rev: Int?
        /// Game Boy: the list's official entry the ROM must be recognised as.
        let official: String?
        let title: String
    }

    var id: String { "\(console)|\(title)|\(version ?? "")|\(code ?? "")|\(sha1.first ?? "")" }
    var isHack: Bool { kind == "hack" }

    static let all: [CompatGame] = {
        guard let url = Bundle.main.url(forResource: "compat", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.games
    }()

    private struct File: Decodable { let games: [CompatGame] }
}

/// What a ROM file is, by its fingerprint or its cart's code.
enum RomIdentity {
    /// The SHA-1 of the file, worked out once per file version (size and date) and kept.
    static func sha1(of url: URL) async -> String? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "sha1|\(url.lastPathComponent)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let known = UserDefaults.standard.string(forKey: key) { return known }
        let digest: String? = await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hasher = Insecure.SHA1()
            while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        if let digest = digest { UserDefaults.standard.set(digest, forKey: key) }
        return digest
    }

    /// The cart's code and revision from its header (GBA at 0xAC / 0xBC, DS at 0x0C / 0x1E).
    static func header(of game: Game) -> (code: String, revision: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: game.romURL) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x200), head.count >= 0x200 else { return nil }
        let ext = game.romURL.pathExtension.lowercased()
        let (at, rev) = ext == "nds" ? (0x0C, 0x1E) : ext == "gba" ? (0xAC, 0xBC) : (-1, -1)
        guard at >= 0, let code = String(data: head[at..<at + 4], encoding: .ascii) else { return nil }
        return (code, Int(head[rev]))
    }

    /// The list's entry for this game: its fingerprint first, else its cart's code (official carts).
    static func match(_ game: Game, sha1: String?) -> CompatGame? {
        if let sha1 = sha1, let byHash = CompatGame.all.first(where: { $0.sha1.contains(sha1) }) {
            return byHash
        }
        guard let header = header(of: game) else { return nil }
        // A hack keeps its base game's header: only an official cart's own size counts as that cart.
        let size = (try? game.romURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let isDS = game.romURL.pathExtension.lowercased() == "nds"
        if !isDS && size > 16 << 20 { return nil }
        return CompatGame.all.first {
            $0.kind == "official" && $0.code == header.code && ($0.revisions?.contains(header.revision) ?? true)
        }
    }
}

struct CompatView: View {
    let games: [Game]

    @State private var search = ""
    @State private var filter = Filter.all
    @State private var console = "Toutes"
    @State private var mine: [Game.ID: (CompatGame?, String?)] = [:]
    /// The official carts in the library (code and revision, or the entry's title for Game Boy): the hacks' bases.
    @State private var owned: [Owned] = []

    struct Owned { let code: String?; let revision: Int?; let title: String }

    /// Where a hack's base stands: in the library, there in another revision, or not there.
    enum BaseState { case have, otherRevision(Int), missing }

    static func state(of base: CompatGame.Base, in owned: [Owned]) -> BaseState {
        if let code = base.code {
            let same = owned.filter { $0.code == code }
            if same.contains(where: { base.rev == nil || $0.revision == base.rev }) { return .have }
            if let other = same.first?.revision { return .otherRevision(other) }
            return .missing
        }
        return owned.contains { $0.title == base.official } ? .have : .missing
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Tous", official = "Officiels", hacks = "Hacks", pokedaisy = "PokeDaisy"
        var id: String { rawValue }
    }

    private var shown: [CompatGame] {
        let query = search.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return CompatGame.all.filter { game in
            (filter == .all || (filter == .pokedaisy ? game.pokedaisy : (filter == .hacks) == game.isHack))
                && (console == "Toutes" || game.console == console)
                && (query.isEmpty || game.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(query))
        }
    }

    var body: some View {
        List {
            Section {
                legend
            }
            if !games.isEmpty {
                Section("Tes jeux") {
                    ForEach(games) { game in
                        myGameRow(game)
                    }
                }
            }
            ForEach(["GBA", "GB", "DS"], id: \.self) { group in
                let rows = shown.filter { $0.console == group }
                if !rows.isEmpty {
                    Section(Self.consoleName(group) + " · \(rows.count)") {
                        ForEach(rows) { game in
                            CompatRow(game: game, owned: owned)
                        }
                    }
                }
            }
            Section {
                Text("La liste dit ce que Capsule reconnaît ; elle ne dit pas où trouver un jeu. Un hack se joue toujours, même absent de la liste : seuls le compagnon et la banque demandent la version exacte. Les hacks se distribuent en patch à appliquer sur ta propre cartouche d'origine.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $search, prompt: "Chercher un jeu")
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                Picker("Type", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Console", selection: $console) {
                    ForEach(["Toutes", "GBA", "GB", "DS"], id: \.self) { Text($0 == "GB" ? "GB / GBC" : $0).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.capsuleBlack)
        }
        .navigationTitle("Jeux compatibles")
        .capsuleScreen()
        .task { await identifyMine() }
    }

    static func consoleName(_ console: String) -> String {
        switch console {
        case "GBA": return "Game Boy Advance"
        case "GB": return "Game Boy / Color"
        default: return "Nintendo DS"
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Se joue : tous les jeux de la liste, et les autres aussi", systemImage: "play.circle")
            Label("iPhone / PC : le compagnon de Capsule (équipe, combats, carte, guide pendant le jeu)", systemImage: "iphone")
            Label("PokeDaisy : le compagnon de l'app PokeDaisy, celui de Capsule sur Android", systemImage: "sparkles")
            Label("Banque : boîtes, banque, Pokédex et échanges", systemImage: "archivebox")
            HStack(spacing: 12) {
                CompatBadge(state: .yes, text: "oui")
                CompatBadge(state: .likely, text: "probable")
                CompatBadge(state: .no, text: "non")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func myGameRow(_ game: Game) -> some View {
        let result = mine[game.id]
        VStack(alignment: .leading, spacing: 4) {
            Text(PokedexStore.gameTitle(game.name)).font(.headline)
            if let result = result {
                if let match = result.0 {
                    Text("Reconnu : \(match.title)\(match.version.map { $0.isEmpty ? "" : " (\($0))" } ?? "")")
                        .font(.subheadline).foregroundStyle(.secondary)
                    CompatRow(game: match, compact: true, owned: owned)
                } else {
                    Text("Version inconnue : il se joue, sans compagnon ; la banque ne l'ouvre que si sa sauvegarde a un format connu.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let sha = result.1 {
                        Text("Empreinte SHA-1 : \(sha)").font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Vérification de l'empreinte…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func identifyMine() async {
        for game in games where mine[game.id] == nil {
            let sha = await RomIdentity.sha1(of: game.romURL)
            let match = RomIdentity.match(game, sha1: sha)
            mine[game.id] = (match, sha)
            if let match, match.kind == "official" {
                let header = RomIdentity.header(of: game)
                owned.append(Owned(code: match.code, revision: header?.revision, title: match.title))
            }
        }
    }
}

enum CompatState { case yes, likely, no }

struct CompatBadge: View {
    let state: CompatState
    let text: String

    var body: some View {
        let color: Color = state == .yes ? .green : state == .likely ? .orange : .secondary
        Label(text, systemImage: state == .yes ? "checkmark.circle.fill" : state == .likely ? "questionmark.circle.fill" : "xmark.circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
    }
}

private struct CompatRow: View {
    let game: CompatGame
    var compact = false
    var owned: [CompatView.Owned] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !compact {
                HStack(alignment: .firstTextBaseline) {
                    Text(game.title).font(.body.weight(.semibold))
                    if let version = game.version, !version.isEmpty {
                        Text(version).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if game.isHack {
                        Text("HACK").font(.caption2.weight(.bold)).foregroundStyle(Color.capsuleAccent)
                    }
                }
            }
            HStack(spacing: 12) {
                CompatBadge(state: game.companion ? .yes : .no, text: "iPhone / PC")
                CompatBadge(state: game.pokedaisy ? .yes : .no, text: "PokeDaisy")
                CompatBadge(state: game.bank == "yes" ? .yes : game.bank == "likely" ? .likely : .no, text: "Banque")
            }
            if let base = game.base {
                baseLine(base)
            }
            if let note = game.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            } else if game.unverified == true {
                Text("Reconnu mais pas encore vérifié en jeu").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, compact ? 0 : 2)
    }

    /// "ROM d'origine : …" and whether the library has it (the patcher's "Patcher un hack" needs it).
    @ViewBuilder private func baseLine(_ base: CompatGame.Base) -> some View {
        let state = CompatView.state(of: base, in: owned)
        VStack(alignment: .leading, spacing: 2) {
            Label("ROM d'origine : \(base.title)", systemImage: "shippingbox")
                .font(.caption)
                .foregroundStyle(.secondary)
            switch state {
            case .have:
                Label("Dans ta bibliothèque : prête pour « Patcher un hack »", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
            case .otherRevision(let revision):
                Label("Tu as une autre révision (\(revision)) : ce hack demande celle indiquée", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            case .missing:
                Label("Pas dans ta bibliothèque", systemImage: "circle.dashed")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
