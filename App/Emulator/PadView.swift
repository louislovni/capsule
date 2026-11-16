import SwiftUI
import UIKit

/// The on-screen controller. Plain UIKit touch handling: every touch that is down
/// contributes its keys, so holding a direction while pressing A or B just works.
final class PadView: UIView {
    var onKeys: ((UInt32) -> Void)?

    /// L and R can be hidden; PokeDaisy's companion uses them on every console, so they show by default.
    var showsShoulders = true {
        didSet {
            guard showsShoulders != oldValue else { return }
            button(PadKey.l)?.isHidden = !showsShoulders
            button(PadKey.r)?.isHidden = !showsShoulders
            setNeedsLayout()
        }
    }

    private struct PadButton {
        let key: UInt32
        let view: UILabel
        /// The small shortcut pills (DS only).
        var isShortcut = false
    }

    /// On a DS game, the face buttons are the game's own and PokeDaisy's tools move
    /// to a row of shortcuts: its DS core opens the companion on L2, the quick
    /// menu on SELECT + L2, steps the screen layouts on R2 and floats the touch
    /// screen in on SELECT + R2.
    var isDS = false {
        didSet {
            guard isDS != oldValue else { return }
            for item in buttons where item.isShortcut {
                item.view.isHidden = !isDS
            }
            setNeedsLayout()
        }
    }

    private static let shortcuts: [(String, UInt32)] = [
        ("COMPAGNON", PadKey.l2),
        ("MENU", PadKey.select | PadKey.l2),
        ("ÉCRANS", PadKey.r2),
        ("TACTILE", PadKey.select | PadKey.r2),
    ]

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

        // X opens PokeDaisy's companion, Y its quick menu.
        let specs: [(String, UInt32)] = [
            ("A", PadKey.a), ("B", PadKey.b), ("X", PadKey.x), ("Y", PadKey.y), ("L", PadKey.l), ("R", PadKey.r),
            ("START", PadKey.start), ("SELECT", PadKey.select),
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
        for (title, key) in Self.shortcuts {
            let label = UILabel()
            label.text = title
            label.textAlignment = .center
            label.textColor = UIColor(white: 1.0, alpha: 0.85)
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.backgroundColor = buttonColor
            label.layer.masksToBounds = true
            label.isUserInteractionEnabled = false
            label.isAccessibilityElement = true
            label.accessibilityTraits = .button
            label.isHidden = true
            addSubview(label)
            buttons.append(PadButton(key: key, view: label, isShortcut: true))
        }
    }

    private func shortcut(_ title: String) -> UILabel? {
        buttons.first { $0.isShortcut && $0.view.text == title }?.view
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
        button(PadKey.l)?.frame = CGRect(x: 16, y: top, width: shoulder.width, height: shoulder.height)
        button(PadKey.r)?.frame = CGRect(x: width - 16 - shoulder.width, y: top, width: shoulder.width, height: shoulder.height)

        // DS: the shortcut row sits between L and R.
        if isDS {
            let count = CGFloat(Self.shortcuts.count)
            let left = 16 + shoulder.width + 8
            let available = width - 2 * left
            let spacing: CGFloat = 6
            let pillWidth = max((available - spacing * (count - 1)) / count, 40)
            for (index, item) in Self.shortcuts.enumerated() {
                shortcut(item.0)?.frame = CGRect(x: left + CGFloat(index) * (pillWidth + spacing), y: top + 4,
                                                 width: pillWidth, height: shoulder.height - 8)
            }
        }

        let pill = CGSize(width: 76, height: 30)
        let bottom = height - pill.height - 18
        button(PadKey.select)?.frame = CGRect(x: width / 2 - pill.width - 10, y: bottom, width: pill.width, height: pill.height)
        button(PadKey.start)?.frame = CGRect(x: width / 2 + 10, y: bottom, width: pill.width, height: pill.height)

        // The main cluster sits between the shoulder row and the START/SELECT row.
        let clusterTop = top + shoulder.height + 10
        let clusterHeight = max(bottom - 10 - clusterTop, 80)
        let centerY = clusterTop + clusterHeight / 2

        let dpadSize = min(width * 0.42, clusterHeight, 170)
        dpad.frame = CGRect(x: 20, y: centerY - dpadSize / 2, width: dpadSize, height: dpadSize)
        let arm = dpadSize / 3
        dpadHorizontal.frame = CGRect(x: 0, y: (dpadSize - arm) / 2, width: dpadSize, height: arm)
        dpadVertical.frame = CGRect(x: (dpadSize - arm) / 2, y: 0, width: arm, height: dpadSize)

        // Four face buttons in a diamond: X top, A right, B bottom, Y left.
        let diameter = min(width * 0.15, clusterHeight * 0.32, 62)
        let gap = diameter * 0.95
        let clusterCenter = CGPoint(x: width - 18 - diameter / 2 - gap, y: centerY)
        let places: [(UInt32, CGPoint)] = [
            (PadKey.x, CGPoint(x: clusterCenter.x, y: clusterCenter.y - gap)),
            (PadKey.a, CGPoint(x: clusterCenter.x + gap, y: clusterCenter.y)),
            (PadKey.b, CGPoint(x: clusterCenter.x, y: clusterCenter.y + gap)),
            (PadKey.y, CGPoint(x: clusterCenter.x - gap, y: clusterCenter.y)),
        ]
        for (key, center) in places {
            button(key)?.frame = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        }

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
                keys |= dx > 0 ? PadKey.right : PadKey.left
            }
            if abs(dy) > abs(dx) * 0.5 {
                keys |= dy > 0 ? PadKey.down : PadKey.up
            }
            return keys
        }
        for item in buttons where !item.view.isHidden && item.view.frame.insetBy(dx: -12, dy: -12).contains(point) {
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
            let down = item.isShortcut ? keys & item.key == item.key : keys & item.key != 0
            item.view.backgroundColor = down ? pressedColor : buttonColor
        }
        let horizontal = keys & (PadKey.left | PadKey.right) != 0
        let vertical = keys & (PadKey.up | PadKey.down) != 0
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
    var showsShoulders = true
    var isDS = false
    let onKeys: (UInt32) -> Void

    func makeUIView(context: Context) -> PadView {
        let view = PadView()
        view.onKeys = onKeys
        view.showsShoulders = showsShoulders
        view.isDS = isDS
        return view
    }

    func updateUIView(_ uiView: PadView, context: Context) {
        uiView.onKeys = onKeys
        uiView.showsShoulders = showsShoulders
        uiView.isDS = isDS
    }

    static func dismantleUIView(_ uiView: PadView, coordinator: ()) {
        uiView.releaseAll()
    }
}

/// The game picture: a layer the emulation thread hands frames to. Touches on it
/// reach the core (PokeDaisy's companion and HUD answer them).
final class ScreenUIView: UIView {
    /// Where the finger is, as a fraction of the picture (0...1), or nil when lifted.
    var onTouch: ((CGPoint?) -> Void)?
    private var tracked: UITouch?

    private func report(_ touch: UITouch) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = touch.location(in: self)
        onTouch?(CGPoint(x: min(max(point.x / bounds.width, 0), 1), y: min(max(point.y / bounds.height, 0), 1)))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracked == nil, let touch = touches.first else { return }
        tracked = touch
        report(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = tracked, touches.contains(touch) {
            report(touch)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = tracked, touches.contains(touch) {
            tracked = nil
            onTouch?(nil)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

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
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Écran du jeu"
    }
}

struct ScreenRepresentable: UIViewRepresentable {
    let session: EmulatorSession

    func makeUIView(context: Context) -> ScreenUIView {
        let view = ScreenUIView()
        session.displayLayer = view.layer
        view.onTouch = { [weak session] point in
            session?.setTouch(point)
        }
        return view
    }

    func updateUIView(_ uiView: ScreenUIView, context: Context) {
        session.displayLayer = uiView.layer
    }
}
