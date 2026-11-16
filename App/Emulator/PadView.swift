import SwiftUI
import UIKit

/// The on-screen controller. Plain UIKit touch handling: every touch that is down
/// contributes its keys, so holding a direction while pressing A or B just works.
final class PadView: UIView {
    var onKeys: ((UInt32) -> Void)?

    private struct PadButton {
        let key: UInt32
        let view: UILabel
    }

    private var buttons: [PadButton] = []
    private let dpad = UIView()
    private let dpadHorizontal = UIView()
    private let dpadVertical = UIView()
    private var activeTouches = Set<UITouch>()
    private var currentKeys: UInt32 = 0
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    private let buttonColor = UIColor(white: 1.0, alpha: 0.16)
    private let pressedColor = UIColor(white: 1.0, alpha: 0.42)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        dpad.isUserInteractionEnabled = false
        for bar in [dpadHorizontal, dpadVertical] {
            bar.backgroundColor = buttonColor
            bar.layer.cornerRadius = 10
            bar.isUserInteractionEnabled = false
            dpad.addSubview(bar)
        }
        addSubview(dpad)

        let specs: [(String, UInt32)] = [
            ("A", GBAKey.a), ("B", GBAKey.b), ("L", GBAKey.l), ("R", GBAKey.r),
            ("START", GBAKey.start), ("SELECT", GBAKey.select),
        ]
        for (title, key) in specs {
            let label = UILabel()
            label.text = title
            label.textAlignment = .center
            label.textColor = UIColor(white: 1.0, alpha: 0.85)
            label.font = .systemFont(ofSize: title.count > 1 ? 11 : 22, weight: .semibold)
            label.backgroundColor = buttonColor
            label.layer.masksToBounds = true
            label.isUserInteractionEnabled = false
            label.isAccessibilityElement = true
            label.accessibilityTraits = .button
            addSubview(label)
            buttons.append(PadButton(key: key, view: label))
        }
    }

    private func button(_ key: UInt32) -> UILabel? {
        buttons.first { $0.key == key }?.view
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }

        let shoulder = CGSize(width: 84, height: 38)
        let top: CGFloat = 12
        button(GBAKey.l)?.frame = CGRect(x: 16, y: top, width: shoulder.width, height: shoulder.height)
        button(GBAKey.r)?.frame = CGRect(x: width - 16 - shoulder.width, y: top, width: shoulder.width, height: shoulder.height)

        let pill = CGSize(width: 76, height: 30)
        let bottom = height - pill.height - 18
        button(GBAKey.select)?.frame = CGRect(x: width / 2 - pill.width - 10, y: bottom, width: pill.width, height: pill.height)
        button(GBAKey.start)?.frame = CGRect(x: width / 2 + 10, y: bottom, width: pill.width, height: pill.height)

        // The main cluster sits between the shoulder row and the START/SELECT row.
        let clusterTop = top + shoulder.height + 10
        let clusterHeight = max(bottom - 10 - clusterTop, 80)
        let centerY = clusterTop + clusterHeight / 2

        let dpadSize = min(width * 0.42, clusterHeight, 170)
        dpad.frame = CGRect(x: 20, y: centerY - dpadSize / 2, width: dpadSize, height: dpadSize)
        let arm = dpadSize / 3
        dpadHorizontal.frame = CGRect(x: 0, y: (dpadSize - arm) / 2, width: dpadSize, height: arm)
        dpadVertical.frame = CGRect(x: (dpadSize - arm) / 2, y: 0, width: arm, height: dpadSize)

        let diameter = min(width * 0.2, clusterHeight * 0.48, 78)
        let aCenter = CGPoint(x: width - 22 - diameter / 2, y: centerY - diameter * 0.35)
        let bCenter = CGPoint(x: aCenter.x - diameter * 1.15, y: centerY + diameter * 0.35)
        button(GBAKey.a)?.frame = CGRect(x: aCenter.x - diameter / 2, y: aCenter.y - diameter / 2, width: diameter, height: diameter)
        button(GBAKey.b)?.frame = CGRect(x: bCenter.x - diameter / 2, y: bCenter.y - diameter / 2, width: diameter, height: diameter)

        for item in buttons {
            item.view.layer.cornerRadius = item.view.bounds.height / 2
        }
    }

    // MARK: - Touches

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

    private func keys(at point: CGPoint) -> UInt32 {
        let dpadArea = dpad.frame.insetBy(dx: -18, dy: -18)
        if dpadArea.contains(point) {
            let dx = point.x - dpad.frame.midX
            let dy = point.y - dpad.frame.midY
            var keys: UInt32 = 0
            if abs(dx) < 10 && abs(dy) < 10 {
                return 0
            }
            // A direction counts when it is at least half as strong as the other
            // one, which leaves room for diagonals.
            if abs(dx) > abs(dy) * 0.5 {
                keys |= dx > 0 ? GBAKey.right : GBAKey.left
            }
            if abs(dy) > abs(dx) * 0.5 {
                keys |= dy > 0 ? GBAKey.down : GBAKey.up
            }
            return keys
        }
        for item in buttons where item.view.frame.insetBy(dx: -12, dy: -12).contains(point) {
            return item.key
        }
        return 0
    }

    private func updateKeys() {
        var keys: UInt32 = 0
        for touch in activeTouches {
            keys |= self.keys(at: touch.location(in: self))
        }
        guard keys != currentKeys else { return }
        if keys & ~currentKeys != 0 {
            feedback.impactOccurred()
        }
        currentKeys = keys
        for item in buttons {
            item.view.backgroundColor = keys & item.key != 0 ? pressedColor : buttonColor
        }
        let horizontal = keys & (GBAKey.left | GBAKey.right) != 0
        let vertical = keys & (GBAKey.up | GBAKey.down) != 0
        dpadHorizontal.backgroundColor = horizontal ? pressedColor : buttonColor
        dpadVertical.backgroundColor = vertical ? pressedColor : buttonColor
        onKeys?(keys)
    }

    /// Releases everything, for when the view goes away mid-press.
    func releaseAll() {
        activeTouches.removeAll()
        updateKeys()
    }
}

struct PadRepresentable: UIViewRepresentable {
    let onKeys: (UInt32) -> Void

    func makeUIView(context: Context) -> PadView {
        let view = PadView()
        view.onKeys = onKeys
        return view
    }

    func updateUIView(_ uiView: PadView, context: Context) {
        uiView.onKeys = onKeys
    }

    static func dismantleUIView(_ uiView: PadView, coordinator: ()) {
        uiView.releaseAll()
    }
}

/// The game picture: a layer the emulation thread hands frames to.
final class ScreenUIView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = .black
        layer.magnificationFilter = .nearest // keep pixels sharp when scaled up
        layer.minificationFilter = .linear
        layer.contentsGravity = .resizeAspect
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Écran du jeu"
    }
}

struct ScreenRepresentable: UIViewRepresentable {
    let session: EmulatorSession

    func makeUIView(context: Context) -> ScreenUIView {
        let view = ScreenUIView()
        session.displayLayer = view.layer
        return view
    }

    func updateUIView(_ uiView: ScreenUIView, context: Context) {
        session.displayLayer = uiView.layer
    }
}
