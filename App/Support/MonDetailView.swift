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
        .capsuleScreen()
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
            if let nature = details.nature {
                row("Nature", "\(nature) (\(details.natureEffect))")
            }
            if !isGameBoy {
                row("Talent", details.ability ?? "Inconnu")
            }
            if details.generation != 1 {
                row("Objet tenu", details.heldItem ?? "Aucun")
            }
            if let friendship = details.friendship {
                row("Bonheur", "\(friendship) / 255")
            }
            row("Expérience", experienceText)
            if let hiddenPower = details.hiddenPower {
                row("Puissance Cachée", hiddenPower)
            }
        }
    }

    private var statsSection: some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Valeur").gridColumnAlignment(.trailing)
                    Text(isGameBoy ? "DV" : "IV").gridColumnAlignment(.trailing)
                    Text(isGameBoy ? "Exp." : "EV").gridColumnAlignment(.trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(0..<statLabels.count, id: \.self) { index in
                    GridRow {
                        Text(statLabels[index])
                            .foregroundStyle(statColor(index))
                        Text(details.stats.flatMap { index < $0.count ? String($0[index]) : nil } ?? "–")
                            .fontWeight(.medium)
                        Text(index < details.ivs.count ? "\(details.ivs[index])" : "–")
                            .foregroundStyle(index < details.ivs.count && details.ivs[index] == maxIV ? Color.green : Color.primary)
                        Text(index < details.evs.count ? "\(details.evs[index])" : "–")
                    }
                    .monospacedDigit()
                }
                Divider()
                if !isGameBoy {
                    GridRow {
                        Text("Total")
                        Text(details.stats.map { String($0.reduce(0, +)) } ?? "–")
                        Text("\(details.ivs.reduce(0, +))")
                        Text("\(details.evs.reduce(0, +))")
                    }
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Statistiques")
        } footer: {
            if isGameBoy {
                Text("DV de 0 à 15 (15 en vert) ; le DV de PV découle des quatre autres. Exp. : l'expérience de statistique, de 0 à 65 535." + (details.generation == 2 ? " Les deux statistiques spéciales partagent le DV et l'expérience du Spécial." : ""))
            } else {
                Text("En rouge la statistique favorisée par la nature, en bleu celle qui est pénalisée. IV de 0 à 31 (31 en vert), EV de 0 à 255, 510 au total.")
            }
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
            if let location = details.metLocation {
                row(details.metLevel == 0 ? "Lieu d'éclosion" : "Lieu de capture", location)
            }
            if let level = details.metLevel {
                row("Niveau de rencontre", level == 0 ? "Éclos d'un Œuf" : "\(level)")
            }
            if let time = details.metTime {
                row("Moment", time)
            }
            if let date = details.metDate {
                row(details.metLevel == 0 ? "Date d'éclosion" : "Date de rencontre", date)
            }
            if let eggLocation = details.eggLocation {
                row("Œuf reçu à", eggLocation)
            }
            if let eggDate = details.eggDate {
                row("Œuf reçu le", eggDate)
            }
            if let ball = details.ball {
                row("Ball", ball)
            }
            row(isGameBoy ? "Jeu" : "Jeu d'origine", details.originGame)
            if let language = details.language {
                row("Langue", language)
            }
            if let bankDate = bankDate {
                row("En banque depuis", bankDate.formatted(date: .long, time: .shortened))
            }
        } header: {
            Text("Rencontre")
        } footer: {
            Text(encounterFootnote)
        }
    }

    private var trainerSection: some View {
        Section("Dresseur d'origine") {
            row("Nom", details.trainerGender.map { "\(details.trainerName) \($0)" } ?? details.trainerName)
            row("ID", String(format: "%05d", details.trainerID))
            if let secretID = details.secretID {
                row("ID secret", String(format: "%05d", secretID))
            }
        }
    }

    private var otherSection: some View {
        Section("Autres") {
            if details.generation != 1 {
                row("Pokérus", details.pokerus ?? "Jamais attrapé")
            }
            if let ribbons = details.ribbons {
                row("Rubans", "\(ribbons)")
            }
            if let contest = details.contest {
                ForEach(0..<min(6, contest.count), id: \.self) { index in
                    row(MonDetails.contestNames[index], "\(contest[index])")
                }
            }
            if let personality = details.personality {
                row("Valeur de personnalité", String(format: "%08X", personality))
            }
            if details.generation == 1 {
                Text("Rouge, Bleu et Jaune n'ont ni objet tenu, ni bonheur, ni Pokérus, ni chromatiques.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var isGameBoy: Bool { details.generation == 1 || details.generation == 2 }
    private var maxIV: Int { isGameBoy ? 15 : 31 }
    private var statLabels: [String] { details.statLabels ?? MonDetails.statNames }

    private var encounterFootnote: String {
        switch details.generation {
        case 1:
            return "Rouge, Bleu et Jaune n'enregistrent ni lieu, ni niveau, ni date de capture."
        case 2:
            return details.metLocation == nil
                ? "Or et Argent n'enregistrent pas les conditions de capture ; seul Cristal garde le lieu, le niveau et le moment. Aucun jeu Game Boy ne garde la date."
                : "Cristal garde le lieu, le niveau et le moment de la capture, mais pas la date."
        case 4, 5:
            return "Les jeux DS enregistrent le lieu, le niveau et la date de la rencontre (selon l'horloge de la console)."
        default:
            return "Les jeux GBA n'enregistrent pas la date de capture : elle n'existe dans aucune sauvegarde de cette génération."
        }
    }

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
