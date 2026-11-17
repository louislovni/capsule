import Combine
import Foundation

/// The list of ROMs in Documents/ROMs, and the import of new files.
final class GameLibrary: ObservableObject {
    @Published private(set) var games: [Game] = []

    init() {
        refresh()
    }

    func refresh() {
        Storage.prepare()
        tidyDocumentsRoot()
        let files = (try? FileManager.default.contentsOfDirectory(at: Storage.roms, includingPropertiesForKeys: nil)) ?? []
        games = files
            .filter { Game.romExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { Game(romURL: $0) }
    }

    /// ROMs and saves left at the top of the app's folder (where the PC's iTunes file sharing
    /// puts them) go to ROMs and Saves. Nothing already there is overwritten.
    private func tidyDocumentsRoot() {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: Storage.documents, includingPropertiesForKeys: nil)) ?? []
        for url in files {
            let ext = url.pathExtension.lowercased()
            let folder: URL
            if Game.romExtensions.contains(ext) {
                folder = Storage.roms
            } else if ext == "sav" {
                folder = Storage.saves
            } else {
                continue
            }
            let target = folder.appendingPathComponent(url.lastPathComponent)
            if !manager.fileExists(atPath: target.path) {
                try? manager.moveItem(at: url, to: target)
            }
        }
    }

    struct ImportResult {
        var roms = 0
        var saves = 0
        var bankFiles: [URL] = []
        var skipped: [String] = []
    }

    /// Copies picked files into the library: .gba, .gb, .gbc, .nds go to ROMs, .sav to Saves.
    /// Existing files are never overwritten. Bank exports (.json) are handed back
    /// to the caller, which merges them.
    func importFiles(_ urls: [URL]) -> ImportResult {
        var result = ImportResult()
        let manager = FileManager.default
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let name = url.lastPathComponent
            switch url.pathExtension.lowercased() {
            case "gba", "gb", "gbc", "nds":
                let destination = Storage.roms.appendingPathComponent(name)
                if manager.fileExists(atPath: destination.path) {
                    result.skipped.append("\(name) (déjà présent)")
                } else if (try? manager.copyItem(at: url, to: destination)) != nil {
                    result.roms += 1
                } else {
                    result.skipped.append("\(name) (copie impossible)")
                }
            case "sav":
                let destination = Storage.saves.appendingPathComponent(name)
                if manager.fileExists(atPath: destination.path) {
                    result.skipped.append("\(name) (une sauvegarde existe déjà)")
                } else if (try? manager.copyItem(at: url, to: destination)) != nil {
                    result.saves += 1
                } else {
                    result.skipped.append("\(name) (copie impossible)")
                }
            case "json":
                // Copy now, while we still have access to the picked file.
                let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
                if (try? manager.copyItem(at: url, to: temporary)) != nil {
                    result.bankFiles.append(temporary)
                } else {
                    result.skipped.append("\(name) (lecture impossible)")
                }
            default:
                result.skipped.append("\(name) (format non pris en charge)")
            }
        }
        refresh()
        return result
    }

    /// Removes the ROM only. The save file, states and backups stay.
    func delete(_ game: Game) {
        try? FileManager.default.removeItem(at: game.romURL)
        refresh()
    }
}
