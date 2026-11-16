import SwiftUI

/// One of PokeDaisy's settings files (key=value lines), read and written whole, keeping
/// every line Capsule doesn't know about. The cores read it when a game starts and write
/// it when a setting changes in their companion, so the app only edits it between games.
final class PokeDaisyINI: ObservableObject {
    let url: URL
    @Published private(set) var values: [String: Int] = [:]
    private var order: [String] = []
    private var other: [String] = [] // lines that aren't key=number

    init(url: URL) {
        self.url = url
        load()
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func load() {
        values = [:]
        order = []
        other = []
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let number = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                let key = String(parts[0])
                if values[key] == nil {
                    order.append(key)
                }
                values[key] = number
            } else if !line.isEmpty {
                other.append(String(line))
            }
        }
    }

    func value(_ key: String, default fallback: Int) -> Int {
        values[key] ?? fallback
    }

    func set(_ key: String, _ value: Int, alsoWrite extra: [String: Int] = [:]) {
        for (k, v) in extra where values[k] == nil {
            values[k] = v
            order.append(k)
        }
        if values[key] == nil {
            order.append(key)
        }
        values[key] = value
        save()
    }

    private func save() {
        var lines = order.compactMap { key in values[key].map { "\(key)=\($0)" } }
        lines.append(contentsOf: other)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }
}

/// PokeDaisy's own options, reachable from the app (the same ones its companion's
/// SETTINGS tab changes in game).
struct PokeDaisySettingsView: View {
    @StateObject private var gba = PokeDaisyINI(url: EmulatorSession.dataDirectory
        .appendingPathComponent("pokedaisy/settings.ini"))
    @StateObject private var ds = PokeDaisyINI(url: EmulatorSession.dataDirectory
        .appendingPathComponent("pokedaisy-ds/settings.ini"))

    var body: some View {
        Form {
            Section {
                Text("Les mêmes réglages que l'onglet SETTINGS du compagnon (bouton X sur GBA, COMPAGNON sur DS). Ils s'appliquent au prochain lancement d'un jeu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("GBA et Game Boy · Image") {
                picker(gba, "aspect", 1, "Format", ["ORIGINAL : l'image du jeu", "EXPAND : la carte jusqu'aux bords", "ZOOM OUT : plus de carte, plus petit"])
                toggle(gba, "autozoom", 1, "Zoom auto (ZOOM OUT revient en EXPAND hors de la carte)")
                toggle(gba, "lcd", 0, "Filtre écran LCD")
            }

            Section("GBA et Game Boy · HUD") {
                toggle(gba, "hud", 1, "HUD sur la carte")
                picker(gba, "hudlayout", 0, "Disposition", ["CORNERS", "CORNERS 2", "RAILS", "DOCK"])
                picker(gba, "hudlook", 0, "Apparence", ["GLASS", "WHITE GLASS", "WINDOW"])
                picker(gba, "hudsize", 1, "Taille", ["Petit", "Normal", "Grand"])
                bitToggle(gba, "hudhide", 0, "Équipe")
                bitToggle(gba, "hudhide", 1, "Mini-carte")
                bitToggle(gba, "hudhide", 2, "Poké Balls")
                bitToggle(gba, "hudhide", 3, "Pas de Repousse")
                bitToggle(gba, "hudhide", 4, "Bouton PC")
                bitToggle(gba, "hudhide", 5, "Bouton Sac")
                bitToggle(gba, "hudhide", 6, "Bouton Sauvages")
            }

            Section("GBA et Game Boy · Jeu") {
                toggle(gba, "wildoff", 0, "Pas de Pokémon sauvages")
                toggle(gba, "runindoors", 0, "Courir à l'intérieur")
                toggle(gba, "autorun", 0, "Course automatique")
                toggle(gba, "onetap", 0, "Attaques en un appui")
                toggle(gba, "gen5", 0, "Infos de combat façon 5e génération")
                toggle(gba, "noinfo", 0, "Masquer les infos de combat")
                toggle(gba, "infofirst", 0, "Infos de combat en premier")
                toggle(gba, "flyclassic", 0, "Vol classique (sans vol libre)")
                toggle(gba, "flightanywhere", 0, "Vol libre partout")
                toggle(gba, "quickgrid", 0, "Menu rapide en grille (sinon en anneau)")
                toggle(gba, "nohints", 0, "Masquer les astuces")
            }

            Section {
                picker(ds, "ds_layout", 0, "Disposition des écrans", ["Un seul écran (auto)", "Écran du haut", "Écran du bas", "Côte à côte", "L'un sous l'autre", "Grand + petit", "Incrustation"])
                toggle(ds, "ds_battlestrip", 1, "Commandes de combat sur l'écran unique")
                toggle(ds, "ds_battles", 1, "Combats automatiquement à l'écran")
                toggle(ds, "hud", 0, "HUD sur la carte")
                toggle(ds, "ds_hudminimal", 0, "HUD minimal")
                picker(ds, "hudsize", 1, "Taille du HUD", ["Petit", "Normal", "Grand"])
                bitToggle(ds, "hudhide", 1, "Mini-carte")
                bitToggle(ds, "hudhide", 2, "Poké Balls")
                bitToggle(ds, "hudhide", 3, "Pas de Repousse")
                toggle(ds, "ds_autorun", 0, "Course automatique")
                picker(ds, "ds_penspeed", 1, "Vitesse du stylet", ["Lente", "Normale", "Rapide"])
                toggle(ds, "quickgrid", 0, "Menu rapide en grille")
                toggle(ds, "wildoff", 0, "Pas de Pokémon sauvages")
                toggle(ds, "ds_darkmode", 0, "Compagnon en mode sombre")
            } header: {
                Text("DS")
            } footer: {
                Text("Le bouton ÉCRANS change aussi la disposition en jeu.")
            }
        }
        .navigationTitle("Réglages PokeDaisy")
        .onAppear {
            gba.load()
            ds.load()
        }
    }

    /// A DS file written from here must hold the DS defaults PokeDaisy would have used.
    private func extraDefaults(_ file: PokeDaisyINI) -> [String: Int] {
        guard file === ds, !file.exists else { return [:] }
        return ["hud": 0, "ds_layout": 0, "ds_battles": 1, "ds_companionbtn": 0, "ds_screenbtn": 1, "ds_penspeed": 1,
                "ds_battlestrip": 1, "ds_hudminimal": 0, "ds_darkmode": 0, "ds_autorun": 0]
    }

    private func toggle(_ file: PokeDaisyINI, _ key: String, _ fallback: Int, _ title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { file.value(key, default: fallback) != 0 },
            set: { file.set(key, $0 ? 1 : 0, alsoWrite: extraDefaults(file)) }
        ))
    }

    private func bitToggle(_ file: PokeDaisyINI, _ key: String, _ bit: Int, _ title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { file.value(key, default: 0) & (1 << bit) == 0 },
            set: { shown in
                var bits = file.value(key, default: 0)
                if shown {
                    bits &= ~(1 << bit)
                } else {
                    bits |= 1 << bit
                }
                file.set(key, bits, alsoWrite: extraDefaults(file))
            }
        ))
    }

    private func picker(_ file: PokeDaisyINI, _ key: String, _ fallback: Int, _ title: String, _ names: [String]) -> some View {
        Picker(title, selection: Binding(
            get: { min(max(file.value(key, default: fallback), 0), names.count - 1) },
            set: { file.set(key, $0, alsoWrite: extraDefaults(file)) }
        )) {
            ForEach(names.indices, id: \.self) { index in
                Text(names[index]).tag(index)
            }
        }
    }
}
