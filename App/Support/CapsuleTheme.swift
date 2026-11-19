import SwiftUI
import UIKit

/// Capsule's look everywhere: warm black around, soft pastel cards, glass round buttons, small capitals for facts and
/// large heavy titles (the controller's and the Pokédex's).
extension Color {
    static let capsuleBlack = Color(red: 0.043, green: 0.039, blue: 0.035)
    static let capsulePanel = Color(red: 0.09, green: 0.082, blue: 0.075)
    static let capsuleCream = Color(red: 0.957, green: 0.937, blue: 0.914)
    static let capsuleInk = Color(red: 0.094, green: 0.141, blue: 0.114)
    /// Buttons and links: the Pokédex's arrows' orange.
    static let capsuleAccent = Color(red: 0.96, green: 0.52, blue: 0.27)
}

enum CapsuleTheme {
    /// Navigation bars: black, heavy titles. Called once as the app starts.
    static func apply() {
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = UIColor(Color.capsuleBlack)
        bar.shadowColor = .clear
        bar.largeTitleTextAttributes = [.font: UIFont.systemFont(ofSize: 34, weight: .heavy),
                                        .foregroundColor: UIColor(Color.capsuleCream)]
        bar.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 17, weight: .bold),
                                   .foregroundColor: UIColor(Color.capsuleCream)]
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
    }

    /// The game's own colour, from its name (Émeraude green, Rubis red...), else its console's.
    static func tint(for game: Game) -> Tint {
        let name = game.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        func has(_ words: String...) -> Bool {
            words.contains { word in name.range(of: "\\b" + word + "\\b", options: .regularExpression) != nil }
        }
        let table: [(Bool, Tint)] = [
            (has("rouge feu", "firered", "fire red"), Tint(r: 0.93, g: 0.42, b: 0.25)),
            (has("vert feuille", "leafgreen", "leaf green"), Tint(r: 0.45, g: 0.78, b: 0.4)),
            (has("heartgold", "heart gold", "or heartgold"), Tint(r: 0.93, g: 0.74, b: 0.3)),
            (has("soulsilver", "soul silver"), Tint(r: 0.62, g: 0.7, b: 0.86)),
            (has("noire 2", "noir 2", "black 2", "blaze black"), Tint(r: 0.36, g: 0.42, b: 0.58)),
            (has("blanche 2", "blanc 2", "white 2", "volt white"), Tint(r: 0.86, g: 0.72, b: 0.62)),
            (has("emeraude", "emerald"), Tint(r: 0.3, g: 0.76, b: 0.5)),
            (has("rubis", "ruby"), Tint(r: 0.86, g: 0.3, b: 0.36)),
            (has("saphir", "sapphire"), Tint(r: 0.3, g: 0.5, b: 0.9)),
            (has("platine", "platinum"), Tint(r: 0.6, g: 0.58, b: 0.72)),
            (has("diamant", "diamond"), Tint(r: 0.48, g: 0.64, b: 0.92)),
            (has("perle", "pearl"), Tint(r: 0.9, g: 0.6, b: 0.75)),
            (has("noire", "noir", "black"), Tint(r: 0.4, g: 0.42, b: 0.5)),
            (has("blanche", "blanc", "white"), Tint(r: 0.84, g: 0.82, b: 0.78)),
            (has("cristal", "crystal"), Tint(r: 0.4, g: 0.78, b: 0.86)),
            (has("argent", "silver"), Tint(r: 0.66, g: 0.7, b: 0.78)),
            (has("or", "gold"), Tint(r: 0.9, g: 0.74, b: 0.3)),
            (has("jaune", "yellow"), Tint(r: 0.95, g: 0.82, b: 0.3)),
            (has("rouge", "red"), Tint(r: 0.9, g: 0.36, b: 0.32)),
            (has("bleue", "bleu", "blue"), Tint(r: 0.36, g: 0.56, b: 0.9)),
            (has("verte", "vert", "green"), Tint(r: 0.4, g: 0.76, b: 0.42)),
        ]
        if let match = table.first(where: { $0.0 }) {
            return match.1
        }
        if game.isDS { return Tint(r: 0.6, g: 0.62, b: 0.7) }
        if game.romURL.pathExtension.lowercased() == "gba" { return Tint(r: 0.6, g: 0.5, b: 0.85) }
        return Tint(r: 0.55, g: 0.75, b: 0.5)
    }

    /// "Sauvé il y a 3 min", "Sauvé le 17 nov.", or "Pas encore de sauvegarde".
    static func savedLine(_ url: URL, now: Date = Date()) -> String {
        guard let date = Storage.modificationDate(of: url) else {
            return "Pas encore de sauvegarde"
        }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Sauvé à l'instant" }
        if seconds < 3600 { return "Sauvé il y a \(Int(seconds / 60)) min" }
        if Calendar.current.isDateInToday(date) {
            return "Sauvé à \(date.formatted(date: .omitted, time: .shortened))"
        }
        if Calendar.current.isDateInYesterday(date) { return "Sauvé hier" }
        return "Sauvé le \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }
}

/// Small capitals with air between the letters: facts and section titles.
struct SmallCaps: ViewModifier {
    var opacity: Double = 0.75
    var color: Color = .capsuleInk

    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .medium))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(color.opacity(opacity))
    }
}

extension View {
    func smallCaps(_ color: Color = .capsuleInk, opacity: Double = 0.75) -> some View {
        modifier(SmallCaps(opacity: opacity, color: color))
    }

    /// A list or form screen in Capsule's look: the warm black behind its rows.
    func capsuleScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.capsuleBlack.ignoresSafeArea())
    }
}

/// A round glass button on a light card.
struct GlassCircle: View {
    let icon: String
    var size: CGFloat = 44
    var ink: Color = .capsuleInk

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(
                Circle().fill(RadialGradient(colors: [.white.opacity(0.8), .white.opacity(0.3)],
                                             center: UnitPoint(x: 0.3, y: 0.2), startRadius: 0, endRadius: size * 0.9))
            )
            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
            .shadow(color: Color(red: 0.24, green: 0.12, blue: 0.04).opacity(0.14), radius: 8, y: 6)
    }
}
