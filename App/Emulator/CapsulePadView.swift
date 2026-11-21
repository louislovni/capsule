import SwiftUI
import UIKit

/// The Capsule skin's controls: a dot-grid pad whose lit dot follows the thumb, four round
/// face buttons and the L / SELECT / START / R pills. Like PadView, every touch that is down
/// adds its keys, so a direction and A can be held together.
final class CapsulePadView: UIView {
    var onKeys: ((UInt32) -> Void)?

    /// The card's strong colour (the A button), taken from the game's picture.
    var accent: UIColor = UIColor(red: 0.17, green: 0.27, blue: 0.21, alpha: 1) {
        didSet { faceA.colors = Self.faceColors(accent, dark: true) }
    }

    private let ink = UIColor(red: 0.094, green: 0.141, blue: 0.114, alpha: 1)

    private let pad = UIView()
    private let dotLayer = CAShapeLayer()
    private let thumb = UIView()

    private final class Face {
        let key: UInt32
        let view = UIView()
        let gradient = CAGradientLayer()
        let label = UILabel()
        var colors: [CGColor] = [] { didSet { gradient.colors = colors } }
        var down = false
        init(key: UInt32) { self.key = key }
    }

    private let faceA = Face(key: PadKey.a)
    private let faceB = Face(key: PadKey.b)
    private let faceX = Face(key: PadKey.x)
    private let faceY = Face(key: PadKey.y)
    private var faces: [Face] { [faceA, faceB, faceX, faceY] }

    private final class Pill {
        let key: UInt32
        let view = UIView()
        let gradient = CAGradientLayer()
        let label = UILabel()
        var down = false
        init(key: UInt32) { self.key = key }
    }

    private let pills: [Pill] = [Pill(key: PadKey.l), Pill(key: PadKey.select), Pill(key: PadKey.start), Pill(key: PadKey.r)]

    private var activeTouches = Set<UITouch>()
    private var currentKeys: UInt32 = 0
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    private let softFeedback = UIImpactFeedbackGenerator(style: .soft)
    /// The dot under the thumb (column, row on the 9 × 9 grid), or nil when the pad is let go.
    private var litDot: (Int, Int)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private static func faceColors(_ base: UIColor, dark: Bool) -> [CGColor] {
        if dark {
            return [base.mixed(with: .white, 0.32).cgColor, base.cgColor]
        }
        return [UIColor(red: 1, green: 0.984, blue: 0.933, alpha: 1).cgColor,
                UIColor(red: 0.89, green: 0.843, blue: 0.706, alpha: 1).cgColor]
    }

    private func setUp() {
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        pad.isUserInteractionEnabled = false
        pad.backgroundColor = UIColor(white: 1, alpha: 0.13)
        pad.layer.borderWidth = 1
        pad.layer.borderColor = ink.withAlphaComponent(0.2).cgColor
        dotLayer.fillColor = ink.withAlphaComponent(0.3).cgColor
        pad.layer.addSublayer(dotLayer)
        thumb.backgroundColor = .white
        thumb.isUserInteractionEnabled = false
        thumb.layer.shadowColor = UIColor.white.cgColor
        thumb.layer.shadowOpacity = 0.8
        thumb.layer.shadowRadius = 7
        thumb.layer.shadowOffset = .zero
        pad.addSubview(thumb)
        addSubview(pad)
        pad.isAccessibilityElement = true
        pad.accessibilityLabel = "Pavé directionnel"

        for (face, title) in [(faceA, "A"), (faceB, "B"), (faceX, "X"), (faceY, "Y")] {
            face.view.isUserInteractionEnabled = false
            face.gradient.type = .radial
            face.gradient.startPoint = CGPoint(x: 0.38, y: 0.3)
            face.gradient.endPoint = CGPoint(x: 1.15, y: 1.15)
            face.colors = Self.faceColors(accent, dark: face === faceA)
            face.view.layer.addSublayer(face.gradient)
            face.view.layer.shadowColor = UIColor(red: 0.08, green: 0.16, blue: 0.12, alpha: 1).cgColor
            face.view.layer.shadowOpacity = 0.24
            face.view.layer.shadowRadius = 8
            face.view.layer.shadowOffset = CGSize(width: 0, height: 7)
            face.label.text = title
            face.label.textAlignment = .center
            face.label.font = .systemFont(ofSize: 21, weight: .bold)
            face.label.textColor = face === faceA ? .white : ink
            face.view.addSubview(face.label)
            face.view.isAccessibilityElement = true
            face.view.accessibilityLabel = title
            face.view.accessibilityTraits = .button
            addSubview(face.view)
        }

        for (pill, title) in zip(pills, ["L", "SELECT", "START", "R"]) {
            pill.view.isUserInteractionEnabled = false
            pill.gradient.type = .radial
            pill.gradient.startPoint = CGPoint(x: 0.3, y: 0.2)
            pill.gradient.endPoint = CGPoint(x: 1.1, y: 1.3)
            pill.gradient.colors = [UIColor(white: 1, alpha: 0.8).cgColor, UIColor(white: 1, alpha: 0.3).cgColor]
            pill.view.layer.addSublayer(pill.gradient)
            pill.view.layer.shadowColor = UIColor(red: 0.08, green: 0.16, blue: 0.12, alpha: 1).cgColor
            pill.view.layer.shadowOpacity = 0.12
            pill.view.layer.shadowRadius = 5
            pill.view.layer.shadowOffset = CGSize(width: 0, height: 4)
            pill.label.text = title
            pill.label.textAlignment = .center
            pill.label.font = .systemFont(ofSize: 12, weight: .semibold)
            pill.label.textColor = ink
            pill.label.attributedText = NSAttributedString(string: title, attributes: [.kern: 1.0])
            pill.view.addSubview(pill.label)
            pill.view.isAccessibilityElement = true
            pill.view.accessibilityLabel = title
            pill.view.accessibilityTraits = .button
            addSubview(pill.view)
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }

        // The pills along the bottom.
        let pillHeight: CGFloat = 40
        let pillY = height - pillHeight
        let widths: [CGFloat] = [64, 92, 92, 64]
        let gap: CGFloat = 10
        var x = (width - widths.reduce(0, +) - gap * 3) / 2
        for (pill, w) in zip(pills, widths) {
            pill.view.bounds = CGRect(x: 0, y: 0, width: w, height: pillHeight)
            pill.view.center = CGPoint(x: x + w / 2, y: pillY + pillHeight / 2)
            pill.gradient.frame = pill.view.bounds
            pill.gradient.cornerRadius = pillHeight / 2
            pill.view.layer.cornerRadius = pillHeight / 2
            pill.label.frame = pill.view.bounds
            x += w + gap
        }

        // The pad on the left, the face buttons on the right, in the room above.
        let clusterHeight = max(pillY - 16, 100)
        let padSize = min(160, clusterHeight, width * 0.43)
        let centerY = clusterHeight / 2
        pad.frame = CGRect(x: 13, y: centerY - padSize / 2, width: padSize, height: padSize)
        pad.layer.cornerRadius = padSize * 0.36
        let margin = padSize * 0.1
        let cell = (padSize - 2 * margin) / 9
        let dots = UIBezierPath()
        for row in 0..<9 {
            for column in 0..<9 {
                let c = CGPoint(x: margin + (CGFloat(column) + 0.5) * cell, y: margin + (CGFloat(row) + 0.5) * cell)
                dots.append(UIBezierPath(ovalIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)))
            }
        }
        dotLayer.path = dots.cgPath
        placeThumb(animated: false)

        let diameter = min(58, clusterHeight / 3.05)
        let step = diameter * 1.02
        let center = CGPoint(x: width - 13 - diameter / 2 - step, y: centerY)
        let places: [(Face, CGPoint)] = [
            (faceX, CGPoint(x: center.x, y: center.y - step)),
            (faceA, CGPoint(x: center.x + step, y: center.y)),
            (faceB, CGPoint(x: center.x, y: center.y + step)),
            (faceY, CGPoint(x: center.x - step, y: center.y)),
        ]
        for (face, point) in places {
            face.view.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            face.view.center = point
            face.gradient.frame = face.view.bounds
            face.gradient.cornerRadius = diameter / 2
            face.view.layer.cornerRadius = diameter / 2
            face.label.frame = face.view.bounds
        }
    }

    /// The lit dot on the touched one, or resting in the middle, with a little spring.
    private func placeThumb(animated: Bool) {
        let size = pad.bounds.width
        guard size > 0 else { return }
        let margin = size * 0.1
        let cell = (size - 2 * margin) / 9
        let (column, row) = litDot ?? (4, 4)
        let lit = litDot != nil
        let side: CGFloat = lit ? 20 : 16
        let center = CGPoint(x: margin + (CGFloat(column) + 0.5) * cell, y: margin + (CGFloat(row) + 0.5) * cell)
        let change = {
            self.thumb.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            self.thumb.layer.cornerRadius = side / 2
            self.thumb.center = center
            self.thumb.alpha = lit ? 1 : 0.85
        }
        thumb.layer.shadowRadius = lit ? 10 : 5
        if animated {
            UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.62, initialSpringVelocity: 0.4,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: change)
        } else {
            change()
        }
    }

    // MARK: - Touches

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if TouchShield.covers(point, in: self) {
            return false
        }
        if pad.frame.insetBy(dx: -16, dy: -16).contains(point) {
            return true
        }
        return faces.contains { $0.view.frame.insetBy(dx: -8, dy: -8).contains(point) }
            || pills.contains { $0.view.frame.insetBy(dx: -4, dy: -6).contains(point) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.formUnion(touches)
        updateKeys()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        updateKeys()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        updateKeys()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        updateKeys()
    }

    /// The keys a touch presses, and for the pad the dot under it.
    private func keys(at point: CGPoint) -> (UInt32, (Int, Int)?) {
        if pad.frame.insetBy(dx: -16, dy: -16).contains(point) {
            let size = pad.bounds.width
            let dx = point.x - pad.frame.midX
            let dy = point.y - pad.frame.midY
            let margin = size * 0.1
            let cell = (size - 2 * margin) / 9
            let column = min(max(Int(((point.x - pad.frame.minX) - margin) / cell), 0), 8)
            let row = min(max(Int(((point.y - pad.frame.minY) - margin) / cell), 0), 8)
            if abs(dx) < size * 0.08 && abs(dy) < size * 0.08 {
                return (0, (column, row))
            }
            var keys: UInt32 = 0
            if abs(dx) > abs(dy) * 0.5 {
                keys |= dx > 0 ? PadKey.right : PadKey.left
            }
            if abs(dy) > abs(dx) * 0.5 {
                keys |= dy > 0 ? PadKey.down : PadKey.up
            }
            return (keys, (column, row))
        }
        // The nearest face button within reach: the four sit close together.
        var best: (Face, CGFloat)?
        for face in faces {
            let distance = hypot(point.x - face.view.center.x, point.y - face.view.center.y)
            if distance < face.view.bounds.width / 2 + 8, distance < (best?.1 ?? .infinity) {
                best = (face, distance)
            }
        }
        if let face = best?.0 {
            return (face.key, nil)
        }
        for pill in pills where pill.view.frame.insetBy(dx: -4, dy: -6).contains(point) {
            return (pill.key, nil)
        }
        return (0, nil)
    }

    private func updateKeys() {
        var keys: UInt32 = 0
        var dot: (Int, Int)?
        for touch in activeTouches {
            let (k, d) = self.keys(at: touch.location(in: self))
            keys |= k
            if let d = d {
                dot = d
            }
        }
        if dot?.0 != litDot?.0 || dot?.1 != litDot?.1 {
            if dot != nil, litDot == nil {
                softFeedback.impactOccurred()
            }
            litDot = dot
            placeThumb(animated: true)
        }
        guard keys != currentKeys else { return }
        if keys & ~currentKeys != 0 {
            feedback.impactOccurred()
        }
        currentKeys = keys
        for face in faces {
            setDown(face.view, down: keys & face.key != 0, was: &face.down, ring: true)
        }
        for pill in pills {
            setDown(pill.view, down: keys & pill.key != 0, was: &pill.down, ring: false)
        }
        onKeys?(keys)
    }

    /// Pressed: squeezed and a little lower, with a ring that spreads out (face buttons);
    /// let go: springs back past its size.
    private func setDown(_ view: UIView, down: Bool, was: inout Bool, ring: Bool) {
        guard down != was else { return }
        was = down
        if down {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                view.transform = CGAffineTransform(translationX: 0, y: 2).scaledBy(x: 0.88, y: 0.88)
                view.layer.shadowOpacity = 0.08
            }
            if ring {
                spreadRing(around: view)
            }
        } else {
            UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.45, initialSpringVelocity: 0.8,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                view.transform = .identity
                view.layer.shadowOpacity = ring ? 0.24 : 0.12
            }
        }
    }

    private func spreadRing(around view: UIView) {
        let ring = CAShapeLayer()
        let side = view.bounds.width + 4
        ring.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        ring.position = view.center
        ring.path = UIBezierPath(ovalIn: ring.bounds).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(white: 1, alpha: 0.85).cgColor
        ring.lineWidth = 2
        layer.insertSublayer(ring, below: view.layer)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.75
        grow.toValue = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: "ring")
        CATransaction.commit()
    }

    func releaseAll() {
        activeTouches.removeAll()
        updateKeys()
    }
}

struct CapsulePadRepresentable: UIViewRepresentable {
    var accent: UIColor
    let onKeys: (UInt32) -> Void

    func makeUIView(context: Context) -> CapsulePadView {
        let view = CapsulePadView()
        view.onKeys = onKeys
        view.accent = accent
        return view
    }

    func updateUIView(_ uiView: CapsulePadView, context: Context) {
        uiView.onKeys = onKeys
        if uiView.accent != accent {
            uiView.accent = accent
        }
    }

    static func dismantleUIView(_ uiView: CapsulePadView, coordinator: ()) {
        uiView.releaseAll()
    }
}

extension UIColor {
    /// This colour moved a fraction of the way towards another.
    func mixed(with other: UIColor, _ amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount,
                       blue: b1 + (b2 - b1) * amount, alpha: a1 + (a2 - a1) * amount)
    }
}
