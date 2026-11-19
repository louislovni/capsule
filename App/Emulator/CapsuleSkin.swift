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

    private let ink = Color(red: 0.094, green: 0.141, blue: 0.114)

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                TintedBackground(tint: session.pictureTint)
                header
                    .padding(.leading, 22)
                    .padding(.trailing, 64)
                    .padding(.top, 24)
                CapsuleWheel(tint: session.pictureTint, tools: tools)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(.top, 10)
                if showsControls {
                    TintedPad(tint: session.pictureTint, session: session)
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
                .menuOrder(.fixed)
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
        title = title.replacingOccurrences(of: "_", with: " ")
        // Patch words and "Version" say nothing: "Version Argent SoulSilver apfix" → "Argent SoulSilver".
        title = title.replacingOccurrences(of: #"(?i)\b(version|ver\.?|apfix|ap fix|patched|patch|fixed|fix|rev ?\d+|v\d+(\.\d+)*)\b"#,
                                           with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–:"))
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

// MARK: - Colours from the picture

/// The card's colours, worked out from the picture's.
enum CardColors {
    private static func hsb(_ tint: Tint) -> (CGFloat, CGFloat, CGFloat) {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: tint.r, green: tint.g, blue: tint.b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return (h, s, v)
    }

    /// Four pastel stops around the picture's colour, a little apart in hue.
    static func stops(_ tint: Tint) -> [Color] {
        let (h, s, _) = hsb(tint)
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
    static func accent(_ tint: Tint) -> UIColor {
        let (h, s, _) = hsb(tint)
        return UIColor(hue: h, saturation: min(max(s, 0.3), 0.6), brightness: 0.38, alpha: 1)
    }
}

/// The card's drifting gradient.
struct TintedBackground: View {
    @ObservedObject var tint: PictureTint
    @State private var drift = false

    var body: some View {
        ZStack {
            LinearGradient(colors: CardColors.stops(tint.value),
                           startPoint: drift ? .topLeading : .top,
                           endPoint: drift ? .bottomTrailing : .bottom)
                .animation(.easeInOut(duration: 8).repeatForever(autoreverses: true), value: drift)
            RadialGradient(colors: [.white.opacity(0.34), .white.opacity(0)],
                           center: UnitPoint(x: 0.8, y: 0.75), startRadius: 0, endRadius: 260)
        }
        .animation(.easeInOut(duration: 1.4), value: tint.value)
        .onAppear { drift = true }
    }
}

/// The controls, their A in the card's strong colour.
struct TintedPad: View {
    @ObservedObject var tint: PictureTint
    let session: EmulatorSession

    var body: some View {
        CapsulePadRepresentable(accent: CardColors.accent(tint.value)) { [weak session] keys in
            session?.setKeys(keys)
        }
    }
}

// MARK: - The side wheel

/// The tools in the notch on the side. A finger rolls the wheel (it snaps to a tool, a tick at
/// each one) or a tap on a tool above or below brings it to the middle; only a tap on the tool in
/// the middle runs it. Its full name shows beside the notch when it comes to the middle.
struct CapsuleWheel: View {
    @ObservedObject var tint: PictureTint
    let tools: [WheelTool]
    /// Sideways: the notch comes down from the top edge and the tools roll left and right.
    var horizontal = false
    /// Tabs rather than tools (the Pokédex's sections): the one rolled to the middle opens at once.
    var opensOnRoll = false

    @State private var index = 0
    @State private var drag: CGFloat = 0
    @State private var moved = false
    @State private var bounce = false
    @State private var caption: String?
    @State private var captionTask: DispatchWorkItem?

    private let item: CGFloat = 34
    /// The window's middle, where the pill is.
    private let middle: CGFloat = 59

    /// Where the wheel stands, in tools (fractional while a finger moves it), held a little past
    /// the ends.
    private var rolled: CGFloat {
        let raw = CGFloat(index) - drag / item
        let last = CGFloat(max(tools.count - 1, 0))
        if raw < 0 { return raw / 3 }
        if raw > last { return last + (raw - last) / 3 }
        return raw
    }

    var body: some View {
        ZStack(alignment: horizontal ? .topLeading : .topTrailing) {
            NotchShape()
                .fill(Color(red: 0.043, green: 0.051, blue: 0.047))
                .frame(width: 56, height: 164)
                .rotationEffect(.degrees(horizontal ? -90 : 0))
                .frame(width: horizontal ? 164 : 56, height: horizontal ? 56 : 164)
            window
                .padding(horizontal ? .leading : .top, 23)
        }
        .frame(width: horizontal ? 164 : 56, height: horizontal ? 56 : 164)
        .overlay(alignment: horizontal ? .top : .topTrailing) {
            if let caption = caption {
                Text(caption)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.043, green: 0.051, blue: 0.047).opacity(0.88), in: Capsule())
                    .offset(x: horizontal ? 0 : -60, y: horizontal ? 62 : 23 + middle - 14)
                    .transition(.opacity.combined(with: .offset(x: 12)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: caption)
    }

    private var window: some View {
        let accent = CardColors.accent(tint.value)
        let rolled = self.rolled
        return ZStack(alignment: horizontal ? .topLeading : .top) {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(LinearGradient(colors: [Color(accent.mixed(with: .white, 0.25)), Color(accent)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(.white.opacity(0.3), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 5, y: 4)
                .frame(width: horizontal ? 54 : 38, height: horizontal ? 38 : 54)
                .scaleEffect(bounce ? 1.14 : 1)
                .offset(x: horizontal ? middle - 27 : 0, y: horizontal ? 4 : middle - 27)
            ForEach(Array(tools.enumerated()), id: \.offset) { offset, tool in
                let distance = abs(CGFloat(offset) - rolled)
                let picked = distance < 0.5
                VStack(spacing: 2) {
                    Image(systemName: tool.icon)
                        .font(.system(size: picked ? 15 : 12, weight: .semibold))
                    Text(tool.short)
                        .font(.system(size: 7, weight: .heavy))
                        .tracking(0.3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .opacity(picked ? 1 : 0)
                }
                .foregroundStyle(picked ? Color.white : Color(red: 0.75, green: 0.8, blue: 0.77))
                .opacity(distance < 0.5 ? 1 : max(0, 0.65 - (distance - 0.5) * 0.45))
                .frame(width: horizontal ? item : 46, height: horizontal ? 46 : item)
                .offset(x: horizontal ? middle - item / 2 + (CGFloat(offset) - rolled) * item : 0,
                        y: horizontal ? 0 : middle - item / 2 + (CGFloat(offset) - rolled) * item)
            }
        }
        .frame(width: horizontal ? 118 : 46, height: horizontal ? 46 : 118, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let along = horizontal ? value.translation.width : value.translation.height
                    if !moved && abs(along) > 6 {
                        moved = true
                    }
                    guard moved else { return }
                    let before = Int(self.rolled.rounded())
                    drag = along
                    let now = Int(self.rolled.rounded())
                    if now != before, (0..<tools.count).contains(now) {
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
                .onEnded { value in
                    let before = index
                    if moved {
                        let target = min(max(Int(rolled.rounded()), 0), tools.count - 1)
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.75)) {
                            index = target
                            drag = 0
                        }
                        moved = false
                        show(tools[target].id)
                        if opensOnRoll && target != before {
                            tools[target].action()
                        }
                    } else {
                        tap(at: horizontal ? value.location.x : value.location.y)
                    }
                }
        )
        .accessibilityElement()
        .accessibilityLabel(tools.indices.contains(index) ? tools[index].id : "Outils")
        .accessibilityHint("Glisse pour changer d'outil, touche pour le lancer")
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? index + 1 : index - 1
            if tools.indices.contains(next) {
                index = next
            }
        }
        .accessibilityAction {
            run()
        }
    }

    private func tap(at y: CGFloat) {
        let slot = Int(((y - middle) / item).rounded())
        let target = index + slot
        guard tools.indices.contains(target) else { return }
        if slot == 0 {
            run()
        } else {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.75)) {
                index = target
            }
            show(tools[target].id)
            if opensOnRoll {
                tools[target].action()
            }
        }
    }

    private func run() {
        guard tools.indices.contains(index) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { bounce = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.45)) { bounce = false }
        }
        tools[index].action()
    }

    /// The tool's full name beside the notch, for a moment.
    private func show(_ name: String) {
        captionTask?.cancel()
        caption = name
        let task = DispatchWorkItem { caption = nil }
        captionTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: task)
    }
}

extension View {
    /// A capsule of Liquid Glass (iOS 26), else a thin blur.
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
