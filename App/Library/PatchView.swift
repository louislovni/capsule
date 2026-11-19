import SwiftUI

/// Creates a ROM hack from a patch (.ips, .ups, .bps, .xdelta) and one of the library's games: the patched
/// ROM becomes a new game, the original stays as it is.
struct PatchView: View {
    let games: [Game]
    /// A patch already picked (from the + button's import); nil to choose one here.
    let initialPatch: URL?
    /// Called with the new game's name once it's in the library.
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var patch: LoadedPatch?
    @State private var base: Game?
    @State private var name = ""
    /// The CRC32 of each game, worked out when a UPS or BPS patch names its source.
    @State private var crcs: [URL: UInt32] = [:]
    @State private var searching = false
    @State private var working = false
    @State private var problem: String?

    /// File extensions of the patches the + button hands to the patcher.
    static let extensions: Set<String> = ["ips", "ups", "bps", "xdelta", "vcdiff", "xd"]

    struct LoadedPatch {
        let fileName: String
        let data: Data
        let format: Int32
        /// UPS and BPS: the CRC32 of the ROM they're made for.
        let sourceCRC: UInt32?

        var formatName: String {
            switch format {
            case Int32(PK_PATCH_IPS): return "IPS"
            case Int32(PK_PATCH_UPS): return "UPS"
            case Int32(PK_PATCH_BPS): return "BPS"
            case Int32(PK_PATCH_XDELTA): return "xdelta"
            default: return "?"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                patchSection
                if patch != nil {
                    baseSection
                    nameSection
                }
                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.capsuleBlack.ignoresSafeArea())
            .navigationTitle("Patcher un hack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Créer") { create() }
                            .disabled(!canCreate)
                    }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { load(url) }
            }
            .onAppear {
                if let initialPatch, patch == nil { load(initialPatch) }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Sections

    private var patchSection: some View {
        Section {
            Button {
                picking = true
            } label: {
                if let patch {
                    HStack {
                        Label(patch.fileName, systemImage: "doc.badge.gearshape")
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(patch.formatName).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    }
                } else {
                    Label("Choisir le patch", systemImage: "doc.badge.plus")
                }
            }
        } header: {
            Text("1 · Le patch")
        } footer: {
            Text("Les hacks se partagent en patch .ips, .ups, .bps ou .xdelta, à appliquer à la ROM d'origine (celle que tu possèdes). Capsule ne télécharge rien.")
        }
    }

    private var baseSection: some View {
        Section {
            if games.isEmpty {
                Text("Importe d'abord le jeu d'origine avec le bouton +.")
                    .foregroundStyle(.secondary)
            }
            ForEach(candidates) { game in
                Button {
                    base = game
                    problem = nil
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.name).foregroundStyle(.primary).lineLimit(2)
                            Text(caption(for: game)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if base == game {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.capsuleAccent)
                        }
                    }
                }
            }
            if searching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Recherche du jeu d'origine…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("2 · Le jeu d'origine")
        } footer: {
            Text(baseFooter)
        }
    }

    private var nameSection: some View {
        Section {
            TextField("Nom du hack", text: $name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        } header: {
            Text("3 · Le nom du nouveau jeu")
        } footer: {
            if let base {
                Text("Il s'ajoutera à ta bibliothèque en .\(base.romURL.pathExtension.lowercased()), avec sa propre sauvegarde. \(base.name) reste tel quel.")
            }
        }
    }

    // MARK: Logic

    /// UPS and BPS: the games whose CRC32 matches first (they're the only ones that work).
    private var candidates: [Game] {
        guard let crc = patch?.sourceCRC else { return games }
        let matching = games.filter { crcs[$0.romURL] == crc }
        return matching + games.filter { crcs[$0.romURL] != crc }
    }

    private func caption(for game: Game) -> String {
        guard let crc = patch?.sourceCRC, let mine = crcs[game.romURL] else { return game.platformLabel }
        return mine == crc ? "\(game.platformLabel) · la bonne version" : "\(game.platformLabel) · pas la version attendue"
    }

    private var baseFooter: String {
        guard let patch else { return "" }
        if let crc = patch.sourceCRC {
            let found = games.contains { crcs[$0.romURL] == crc }
            if searching { return "Ce patch dit pour quelle ROM il est fait : Capsule la cherche dans ta bibliothèque." }
            return found
                ? "Trouvé : ce patch est fait pour ce jeu-là."
                : "Aucun de tes jeux n'est la ROM attendue (CRC32 \(String(format: "%08X", crc))). Il faut la version exacte du jeu d'origine, souvent la version anglaise ou française indiquée par l'auteur du hack."
        }
        if patch.format == Int32(PK_PATCH_IPS) {
            return "Un patch IPS ne vérifie pas le jeu d'origine : choisis bien celui que l'auteur indique, sinon le hack ne marchera pas."
        }
        return "Choisis le jeu indiqué par l'auteur du hack : Capsule vérifiera que c'est la bonne version."
    }

    private var canCreate: Bool {
        patch != nil && base != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty && !working
    }

    private func load(_ url: URL) {
        problem = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            problem = "Le fichier n'a pas pu être lu."
            return
        }
        let format = data.withUnsafeBytes { pk_patch_format($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        guard format != Int32(PK_PATCH_UNKNOWN) else {
            patch = nil
            problem = "Ce fichier n'est pas un patch reconnu (.ips, .ups, .bps ou .xdelta). Si c'est un .zip ou un .rar, ouvre-le d'abord dans l'app Fichiers."
            return
        }
        var crc: UInt32 = 0
        let hasCRC = data.withUnsafeBytes { pk_patch_source_crc($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &crc) } != 0
        patch = LoadedPatch(fileName: url.lastPathComponent, data: data, format: format, sourceCRC: hasCRC ? crc : nil)
        name = url.deletingPathExtension().lastPathComponent
        base = nil
        if hasCRC { findBase(crc) }
    }

    /// Works out the CRC32 of each ROM (off the main thread) and picks the one the patch names.
    private func findBase(_ crc: UInt32) {
        searching = true
        let games = self.games
        Task {
            for game in games where crcs[game.romURL] == nil {
                let value = await Task.detached(priority: .userInitiated) { () -> UInt32? in
                    guard let data = try? Data(contentsOf: game.romURL, options: .alwaysMapped) else { return nil }
                    return data.withUnsafeBytes { pk_crc32($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
                }.value
                if let value { crcs[game.romURL] = value }
                if value == crc, base == nil { base = game }
            }
            searching = false
        }
    }

    private func create() {
        guard let patch, let base else { return }
        let cleaned = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let destination = Storage.roms.appendingPathComponent(cleaned).appendingPathExtension(base.romURL.pathExtension.lowercased())
        if FileManager.default.fileExists(atPath: destination.path) {
            problem = "Un jeu porte déjà ce nom : choisis-en un autre."
            return
        }
        working = true
        problem = nil
        let patchData = patch.data
        let sourceURL = base.romURL
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Void, PatchError> in
                guard let source = try? Data(contentsOf: sourceURL, options: .alwaysMapped) else { return .failure(.unreadable) }
                var out: UnsafeMutablePointer<UInt8>?
                var outSize = 0
                let code = source.withUnsafeBytes { src in
                    patchData.withUnsafeBytes { p in
                        pk_patch_apply(src.bindMemory(to: UInt8.self).baseAddress, src.count,
                                       p.bindMemory(to: UInt8.self).baseAddress, p.count, &out, &outSize)
                    }
                }
                defer { pk_patch_free(out) }
                guard code == 0, let out else { return .failure(.code(code)) }
                do {
                    try Data(bytesNoCopy: out, count: outSize, deallocator: .none).write(to: destination, options: .atomic)
                    return .success(())
                } catch {
                    return .failure(.unwritable)
                }
            }.value
            working = false
            switch outcome {
            case .success:
                onCreated(cleaned)
                dismiss()
            case .failure(let error):
                problem = error.message
            }
        }
    }

    enum PatchError: Error {
        case unreadable, unwritable, code(Int32)

        var message: String {
            switch self {
            case .unreadable: return "Le jeu d'origine n'a pas pu être lu."
            case .unwritable: return "Le hack n'a pas pu être enregistré (plus de place sur l'iPhone ?)."
            case .code(let code):
                switch code {
                case Int32(PK_PATCH_ERR_WRONG_SOURCE), Int32(PK_PATCH_ERR_RESULT):
                    return "Ce patch n'est pas fait pour ce jeu (ou pas pour cette version). Vérifie la ROM d'origine indiquée par l'auteur du hack : langue, version 1.0 ou 1.1, etc."
                case Int32(PK_PATCH_ERR_CORRUPT):
                    return "Le patch est abîmé ou incomplet. Retélécharge-le."
                case Int32(PK_PATCH_ERR_UNSUPPORTED):
                    return "Ce patch utilise une option que Capsule ne sait pas lire (compression FGK). Demande une version .bps ou .xdelta standard."
                case Int32(PK_PATCH_ERR_MEMORY):
                    return "Pas assez de mémoire pour créer ce hack. Ferme les autres apps et réessaie."
                default:
                    return "Ce fichier n'est pas un patch reconnu."
                }
            }
        }
    }
}
