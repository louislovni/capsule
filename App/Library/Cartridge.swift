import CoreMotion
import SwiftUI

/// The phone's tilt, for the cartridges' 3D: roll and pitch in radians around how it was held when it started,
/// smoothed. One for the whole home screen; it runs only while the screen is shown.
final class PhoneTilt: ObservableObject {
    @Published private(set) var x: Double = 0
    @Published private(set) var y: Double = 0

    private let motion = CMMotionManager()
    private var rest: (Double, Double)?

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        rest = nil
        motion.deviceMotionUpdateInterval = 1.0 / 24
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self = self, let attitude = data?.attitude else { return }
            let now = (attitude.roll, attitude.pitch)
            if self.rest == nil { self.rest = now }
            // The rest position follows slowly: a phone held another way settles back to flat.
            self.rest!.0 += (now.0 - self.rest!.0) * 0.01
            self.rest!.1 += (now.1 - self.rest!.1) * 0.01
            let targetX = max(-0.35, min(0.35, now.0 - self.rest!.0))
            let targetY = max(-0.35, min(0.35, now.1 - self.rest!.1))
            let nextX = self.x + (targetX - self.x) * 0.3
            let nextY = self.y + (targetY - self.y) * 0.3
            // Only a change that shows: a still phone redraws nothing.
            if abs(nextX - self.x) > 0.002 || abs(nextY - self.y) > 0.002 {
                self.x = nextX
                self.y = nextY
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        x = 0
        y = 0
    }
}

/// Which kind of cartridge a game is drawn as: our own shapes in the spirit of each console's.
enum CartridgeKind {
    case wide   // the Game Boy Advance's: wider than tall
    case tall   // the Game Boy's: taller than wide, a corner cut
    case card   // the DS's: a small card

    init(_ game: Game) {
        switch game.romURL.pathExtension.lowercased() {
        case "gba": self = .wide
        case "nds": self = .card
        default: self = .tall
        }
    }

    /// Width over height.
    var aspect: CGFloat {
        switch self {
        case .wide: return 1.62
        case .tall: return 0.92
        case .card: return 1.12
        }
    }
}

/// The cartridge's outline.
struct CartridgeShape: Shape {
    let kind: CartridgeKind

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = min(w, h) * 0.07
        var path = Path()
        switch kind {
        case .wide:
            // Rounded, its top edge dipping a little in the middle where a finger pulls it out.
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.36, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.64, y: rect.minY),
                              control: CGPoint(x: rect.midX, y: rect.minY + h * 0.07))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r * 1.6))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r * 1.6, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r * 1.6, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r * 1.6), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        case .tall:
            // Square-ish corners, the top right one cut.
            let cut = w * 0.12
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        case .card:
            // A card with a small step on its left edge.
            let step = h * 0.18
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r + w * 0.04, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.04, y: rect.maxY - r), control: CGPoint(x: rect.minX + w * 0.04, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.04, y: rect.minY + step))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + step - w * 0.04))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

/// A game as a cartridge in its colour, with a label of our own (its name, its console), drawn with some depth and
/// turning a little with the phone. The drawing is flattened once into one image (drawingGroup); only its turn
/// changes as the phone moves, which costs nothing to redraw. The finger doesn't turn it: a swipe scrolls the list.
struct CartridgeView: View {
    let game: Game
    @ObservedObject var tilt: PhoneTilt

    var body: some View {
        CartridgeFace(game: game)
            .rotation3DEffect(.degrees(tilt.y * 22), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tilt.x * 22), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .accessibilityHidden(true)
    }
}

/// The cartridge itself, still.
struct CartridgeFace: View {
    let game: Game

    private var kind: CartridgeKind { CartridgeKind(game) }

    var body: some View {
        let tint = CapsuleTheme.tint(for: game)
        let plastic = Color(UIColor(red: tint.r, green: tint.g, blue: tint.b, alpha: 1).mixed(with: .black, 0.18))
        let edge = Color(UIColor(red: tint.r, green: tint.g, blue: tint.b, alpha: 1).mixed(with: .black, 0.5))
        GeometryReader { geometry in
            let depth = min(geometry.size.width, geometry.size.height) * 0.05
            // The face: the outline's size, the thickness below it.
            let size = CGSize(width: geometry.size.width, height: geometry.size.height - depth)
            ZStack {
                // The thickness: the outline repeated downwards in the plastic's dark side.
                ForEach(0..<3, id: \.self) { layer in
                    CartridgeShape(kind: kind)
                        .fill(edge)
                        .offset(y: depth * CGFloat(3 - layer) / 3)
                }
                CartridgeShape(kind: kind)
                    .fill(LinearGradient(colors: [plastic.opacity(0.95), plastic], startPoint: .top, endPoint: .bottom))
                grip(size)
                label(size, tint: tint)
                // Light on the plastic, moving as it turns.
                CartridgeShape(kind: kind)
                    .fill(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0), .white.opacity(0.1)],
                                         startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1)))
                CartridgeShape(kind: kind)
                    .stroke(.white.opacity(0.25), lineWidth: 1)
            }
            .frame(width: size.width, height: size.height)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .aspectRatio(kind.aspect, contentMode: .fit)
        .padding(.bottom, 16)
        .background(alignment: .bottom) {
            // Its shadow on the card: a soft dark oval, cheaper than a blurred copy of the whole cartridge.
            Ellipse()
                .fill(RadialGradient(colors: [.black.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: 140))
                .frame(height: 34)
                .padding(.horizontal, 10)
        }
        .drawingGroup()
    }

    /// Ridges where the fingers hold it.
    @ViewBuilder private func grip(_ size: CGSize) -> some View {
        let lines = 5
        switch kind {
        case .wide:
            VStack(spacing: size.height * 0.025) {
                ForEach(0..<lines, id: \.self) { _ in
                    Capsule().fill(.black.opacity(0.16)).frame(width: size.width * 0.16, height: 2)
                }
            }
            .position(x: size.width * 0.5, y: size.height * 0.86)
        case .tall:
            VStack(spacing: size.height * 0.022) {
                ForEach(0..<lines, id: \.self) { _ in
                    Capsule().fill(.black.opacity(0.16)).frame(width: size.width * 0.5, height: 2)
                }
            }
            .position(x: size.width * 0.42, y: size.height * 0.1)
        case .card:
            EmptyView()
        }
    }

    /// The sticker: the game's pastel, its name large, its console in small capitals.
    private func label(_ size: CGSize, tint: Tint) -> some View {
        let frame: CGRect
        switch kind {
        case .wide: frame = CGRect(x: size.width * 0.07, y: size.height * 0.12, width: size.width * 0.86, height: size.height * 0.6)
        case .tall: frame = CGRect(x: size.width * 0.09, y: size.height * 0.28, width: size.width * 0.82, height: size.height * 0.62)
        case .card: frame = CGRect(x: size.width * 0.12, y: size.height * 0.1, width: size.width * 0.8, height: size.height * 0.62)
        }
        let corner = min(frame.width, frame.height) * 0.08
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: CardColors.stops(tint), startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(RadialGradient(colors: [.white.opacity(0.4), .white.opacity(0)], center: UnitPoint(x: 0.85, y: 0.1),
                                     startRadius: 0, endRadius: frame.width * 0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text(game.platformLabel)
                    .font(.system(size: max(7, frame.height * 0.07), weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.capsuleInk.opacity(0.7))
                    .lineLimit(1)
                Text(CapsuleCard<EmptyView>.displayTitle(game.name))
                    .font(.system(size: frame.height * 0.24, weight: .heavy))
                    .tracking(-0.6)
                    .foregroundStyle(Color(red: 0.063, green: 0.06, blue: 0.05))
                    .lineLimit(2)
                    .minimumScaleFactor(0.4)
            }
            .padding(frame.height * 0.1)
        }
        .frame(width: frame.width, height: frame.height)
        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        .position(x: frame.midX, y: frame.midY)
    }
}
