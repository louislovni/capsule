import SwiftUI

/// The full sheet of one Pokémon.
struct MonDetailView: View {
    let details: MonDetails
    /// When the Pokémon entered the bank, if it is there.
    var bankDate: Date?

    var body: some View {
        List {
            header
            if !details.isEgg {
                characteristics
                statsSection
                movesSection
            }
            captureSection
            trainerSection
            if !details.isEgg {
                otherSection
            }
        }
        .navigationTitle(details.isEgg ? "Œuf" : details.speciesName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(details.isEgg ? "Œuf" : (details.nickname.isEmpty ? details.speciesName : details.nickname))
                        .font(.title2.weight(.semibold))
                    if let gender = details.gender, !details.isEgg {
                        Text(gender)
                            .font(.title3)
                            .foregroundStyle(gender == "♀" ? Color.pink : Color.blue)
                    }
                    if details.isShiny {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Chromatique")
                    }
                    Spacer()
                    if details.level > 0 && !details.isEgg {
                        Text("N. \(details.level)")
                            .font(.headline)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 8) {
                    Text(details.nationalDex.map { "N° \(String(format: "%03d", $0)) · \(details.speciesName)" } ?? details.speciesName)
                        .foregroundStyle(.secondary)
                    ForEach(details.types, id: \.self) { type in
                        Text(type)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                .font(.subheadline)
                if let hp = details.currentHP, let maxHP = details.stats?.first {
                    HStack {
                        Text("PV \(hp)/\(maxHP)")
                            .monospacedDigit()
                        if let status = details.status {
                            Text(status)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.25), in: Capsule())
                        }
                    }
                    .font(.subheadline)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var characteristics: some View {
        Section("Caractéristiques") {
            row("Nature", "\(details.nature) (\(details.natureEffect))")
            row("Talent", details.ability ?? "Inconnu")
            row("Objet tenu", details.heldItem ?? "Aucun")
            row("Bonheur", "\(details.friendship) / 255")
            row("Expérience", experienceText)
            row("Puissance Cachée", details.hiddenPower)
        }
    }

    private var statsSection: some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Valeur").gridColumnAlignment(.trailing)
                    Text("IV").gridColumnAlignment(.trailing)
                    Text("EV").gridColumnAlignment(.trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(0..<6, id: \.self) { index in
                    GridRow {
                        Text(MonDetails.statNames[index])
                            .foregroundStyle(statColor(index))
                        Text(details.stats.map { String($0[index]) } ?? "–")
                            .fontWeight(.medium)
                        Text("\(details.ivs[index])")
                            .foregroundStyle(details.ivs[index] == 31 ? Color.green : Color.primary)
                        Text("\(details.evs[index])")
                    }
                    .monospacedDigit()
                }
                Divider()
                GridRow {
                    Text("Total")
                    Text(details.stats.map { String($0.reduce(0, +)) } ?? "–")
                    Text("\(details.ivs.reduce(0, +))")
                    Text("\(details.evs.reduce(0, +))")
                }
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            }
            .padding(.vertical, 4)
        } header: {
            Text("Statistiques")
        } footer: {
            Text("En rouge la statistique favorisée par la nature, en bleu celle qui est pénalisée. IV de 0 à 31 (31 en vert), EV de 0 à 255, 510 au total.")
        }
    }

    private var movesSection: some View {
        Section("Capacités") {
            if details.moves.isEmpty {
                Text("Aucune")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(details.moves.enumerated()), id: \.offset) { _, move in
                row(move.name, "PP \(move.pp)")
            }
        }
    }

    private var captureSection: some View {
        Section {
            row(details.metLevel == 0 ? "Lieu d'éclosion" : "Lieu de capture", details.metLocation)
            row("Niveau de rencontre", details.metLevel == 0 ? "Éclos d'un Œuf" : "\(details.metLevel)")
            row("Ball", details.ball)
            row("Jeu d'origine", details.originGame)
            row("Langue", details.language)
            if let bankDate = bankDate {
                row("En banque depuis", bankDate.formatted(date: .long, time: .shortened))
            }
        } header: {
            Text("Rencontre")
        } footer: {
            Text("Les jeux GBA n'enregistrent pas la date de capture : elle n'existe dans aucune sauvegarde de cette génération.")
        }
    }

    private var trainerSection: some View {
        Section("Dresseur d'origine") {
            row("Nom", "\(details.trainerName) \(details.trainerGender)")
            row("ID", String(format: "%05d", details.trainerID))
            row("ID secret", String(format: "%05d", details.secretID))
        }
    }

    private var otherSection: some View {
        Section("Autres") {
            row("Pokérus", details.pokerus ?? "Jamais attrapé")
            row("Rubans", "\(details.ribbons)")
            ForEach(0..<6, id: \.self) { index in
                row(MonDetails.contestNames[index], "\(details.contest[index])")
            }
            row("Valeur de personnalité", String(format: "%08X", details.personality))
        }
    }

    // MARK: - Helpers

    private var experienceText: String {
        if let next = details.experienceToNext {
            return "\(details.experience) (encore \(next) pour le niveau \(details.level + 1))"
        }
        return "\(details.experience)"
    }

    private func statColor(_ index: Int) -> Color {
        if index == details.natureRaised { return .red }
        if index == details.natureLowered { return .blue }
        return .primary
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Opens a detail sheet for Pokémon whose details must be worked out first
/// (reading the ROM takes a moment).
struct MonDetailLoader: View {
    let load: () -> MonDetails?
    var bankDate: Date?

    @State private var details: MonDetails?
    @State private var failed = false

    var body: some View {
        Group {
            if let details = details {
                MonDetailView(details: details, bankDate: bankDate)
            } else if failed {
                Text("Ce Pokémon n'a pas pu être lu.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task {
            let work = load
            let result = await Task.detached(priority: .userInitiated) { work() }.value
            details = result
            failed = result == nil
        }
    }
}
