import SwiftUI
import UIKit

/// How the on-screen controller looks upright: Capsule's card, or the plain see-through one
/// over a picture that takes the whole screen.
enum PadSkin: String, CaseIterable, Identifiable {
    case capsule
    case plain

    var id: String { rawValue }
    var title: String { self == .capsule ? "Capsule" : "Vierge (plein écran)" }

    static let storageKey = "padSkin"
}

/// One tool on the side wheel.
struct WheelTool: Identifiable {
    let id: String
    let short: String
    let icon: String
    let action: () -> Void
}

/// The Capsule controller upright: a rounded card under the picture whose soft gradient takes
/// the game's colours, with the game's name, the speed, a wheel of tools in a notch on the side,
/// and the controls.
struct CapsuleCard<MenuContent: View>: View {
    @ObservedObject var session: EmulatorSession
    let showsControls: Bool
    let tools: [WheelTool]
    let onQuit: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    @State private var drift = false
    @State private var toolIndex = 0
    /// Counts the runs of the tool in the pill: each makes the pill bounce.
    @State private var fired = 0
    @State private var bounce = false
    @GestureState private var wheelDrag: CGFloat = 0

    private let ink = Color(red: 0.094, green: 0.141, blue: 0.114)
    private static var itemHeight: CGFloat { 34 }

    // MARK: Colours

    private var base: UIColor {
        let t = session.tint
        return UIColor(red: t.r, green: t.g, blue: t.b, alpha: 1)
    }

    /// Three pastel stops around the picture's colour, a little apart in hue.
    private var gradientStops: [Color] {
        let b = base
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        b.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let sat = min(max(s, 0.18), 0.5)
        func pastel(_ dh: CGFloat, _ light: CGFloat) -> Color {
            var hue = h + dh
            if hue < 0 { hue += 1 }
            if hue > 1 { hue -= 1 }
            return Color(UIColor(hue: hue, saturation: sat, brightness: 0.82, alpha: 1).mixed(with: .white, light))
        }
        return [pastel(-0.04, 0.3), pastel(0.03, 0.5), pastel(0.12, 0.42), pastel(0, 0.36)]
    }

    /// The strong colour: A and the wheel's pill.
    private var accent: UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return UIColor(hue: h, saturation: min(max(s, 0.3), 0.6), brightness: 0.38, alpha: 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                background
                header
                    .padding(.leading, 22)
                    .padding(.trailing, 64)
                    .padding(.top, 24)
                notch
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(.top, 10)
                if showsControls {
                    CapsulePadRepresentable(accent: accent) { [weak session] keys in
                        session?.setKeys(keys)
                    }
                    .frame(width: size.width, height: max(size.height - 182 - 24, 120))
                    .offset(y: 182)
                } else {
                    Text("Manette Bluetooth connectée")
                        .font(.footnote.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1.5)
                        .foregroundStyle(ink.opacity(0.6))
                        .frame(width: size.width, height: size.height - 182)
                        .offset(y: 182)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .onAppear { drift = true }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: gradientStops,
                           startPoint: drift ? .topLeading : .top,
                           endPoint: drift ? .bottomTrailing : .bottom)
                .animation(.easeInOut(duration: 8).repeatForever(autoreverses: true), value: drift)
            RadialGradient(colors: [.white.opacity(0.34), .white.opacity(0)],
                           center: UnitPoint(x: 0.8, y: 0.75), startRadius: 0, endRadius: 260)
        }
        .animation(.easeInOut(duration: 1.4), value: session.tint.r + session.tint.g * 2 + session.tint.b * 3)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("\(session.game.platformLabel)\n\(savedLine(now: context.date))")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .lineSpacing(3)
                    .foregroundStyle(ink.opacity(0.78))
            }
            Text(Self.displayTitle(session.game.name))
                .font(.system(size: 44, weight: .heavy))
                .tracking(-1.2)
                .lineLimit(2)
                .minimumScaleFactor(0.45)
                .foregroundStyle(Color(red: 0.063, green: 0.102, blue: 0.078))
                .frame(height: 50, alignment: .bottomLeading)
            HStack(spacing: 8) {
                speedSelector
                glassButton(systemImage: "xmark", label: "Quitter", action: onQuit)
                Menu {
                    menu()
                } label: {
                    glassCircle(systemImage: "ellipsis")
                }
                .accessibilityLabel("Plus")
            }
        }
    }

    private func savedLine(now: Date) -> String {
        guard let date = Storage.modificationDate(of: session.game.saveURL) else {
            return "Pas encore de sauvegarde"
        }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Sauvé à l'instant" }
        if seconds < 3600 { return "Sauvé il y a \(Int(seconds / 60)) min" }
        if Calendar.current.isDateInToday(date) {
            return "Sauvé à \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "Sauvé le \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    /// "Pokemon - Version Emeraude (France)" → "Version Emeraude".
    static func displayTitle(_ name: String) -> String {
        var title = name.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"^(Pok[eé]mon)\s*[-:–]?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        title = title.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? name : title
    }

    private var speedSelector: some View {
        let speeds = EmulatorSession.speeds
        let index = speeds.firstIndex(of: session.speed) ?? 0
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.85))
                .shadow(color: Color(red: 0.08, green: 0.16, blue: 0.12).opacity(0.18), radius: 3, y: 2)
                .frame(width: 34, height: 24)
                .offset(x: 2 + CGFloat(index) * 34.7)
                .animation(.spring(response: 0.32, dampingFraction: 0.6), value: index)
            HStack(spacing: 0) {
                ForEach(speeds, id: \.self) { speed in
                    Button {
                        session.setSpeed(speed)
                    } label: {
                        Text("×\(speed)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(speed == session.speed ? ink : ink.opacity(0.5))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Vitesse \(speed) fois")
                }
            }
            .padding(2)
        }
        .frame(width: 108, height: 28)
        .background(ink.opacity(0.1), in: Capsule())
    }

    private func glassCircle(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(ink)
            .frame(width: 28, height: 28)
            .background(
                Circle().fill(RadialGradient(colors: [.white.opacity(0.8), .white.opacity(0.3)],
                                             center: UnitPoint(x: 0.3, y: 0.2), startRadius: 0, endRadius: 26))
            )
            .shadow(color: Color(red: 0.08, green: 0.16, blue: 0.12).opacity(0.12), radius: 4, y: 3)
    }

    private func glassButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            glassCircle(systemImage: systemImage)
        }
        .buttonStyle(SquishStyle())
        .accessibilityLabel(label)
    }

    // MARK: The notch and its wheel

    private var notch: some View {
        ZStack(alignment: .topTrailing) {
            NotchShape()
                .fill(Color(red: 0.043, green: 0.051, blue: 0.047))
                .frame(width: 56, height: 164)
            wheel
                .frame(width: 46, height: 118)
                .clipped()
                .padding(.top, 23)
        }
    }

    private var wheel: some View {
        let itemHeight = Self.itemHeight
        let rolled = CGFloat(toolIndex) - wheelDrag / itemHeight
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(LinearGradient(colors: [Color(accent.mixed(with: .white, 0.25)), Color(accent)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .stroke(.white.opacity(0.3), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 5, y: 4)
                .frame(width: 38, height: 54)
                .scaleEffect(bounce ? 1.14 : 1)
                .padding(.top, 32)
            VStack(spacing: 0) {
                ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                    let distance = abs(CGFloat(index) - rolled)
                    let picked = distance < 0.5
                    Button {
                        if index == toolIndex {
                            // The tool in the pill runs; any other one only rolls into it.
                            fired += 1
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            tool.action()
                        } else {
                            roll(to: index)
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: tool.icon)
                                .font(.system(size: picked ? 15 : 12, weight: .semibold))
                            if picked {
                                Text(tool.short)
                                    .font(.system(size: 7, weight: .heavy))
                                    .tracking(0.3)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                        }
                        .foregroundStyle(picked ? Color.white
                                         : Color(red: 0.75, green: 0.8, blue: 0.77).opacity(distance < 1.5 ? 0.6 : 0))
                        .frame(width: 46, height: itemHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tool.id)
                    .accessibilityHint(index == toolIndex ? "Touche pour lancer" : "Touche pour le placer au centre")
                }
            }
            .offset(y: 59 - itemHeight / 2 - rolled * itemHeight)
        }
        .frame(width: 46, height: 118, alignment: .top)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 6)
                .updating($wheelDrag) { value, state, _ in
                    state = value.translation.height
                }
                .onEnded { value in
                    let target = Int((CGFloat(toolIndex) - value.translation.height / itemHeight).rounded())
                    roll(to: min(max(target, 0), tools.count - 1))
                }
        )
        .animation(.spring(response: 0.5, dampingFraction: 0.62), value: toolIndex)
        .onChange(of: fired) { _ in
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { bounce = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.45)) { bounce = false }
            }
        }
    }

    private func roll(to index: Int) {
        if index != toolIndex {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        toolIndex = index
    }
}

/// The side notch: the black of the screen's edge coming into the card in a soft curve.
struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 56, sy = rect.height / 164
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(56, 0))
        path.addCurve(to: p(10, 48), control1: p(56, 22), control2: p(10, 18))
        path.addLine(to: p(10, 116))
        path.addCurve(to: p(56, 164), control1: p(10, 146), control2: p(56, 142))
        path.closeSubpath()
        return path
    }
}

/// Squeezed while held, springing back past its size when let go.
struct SquishStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .offset(y: configuration.isPressed ? 1.5 : 0)
            .animation(.spring(response: 0.35, dampingFraction: 0.45), value: configuration.isPressed)
    }
}
