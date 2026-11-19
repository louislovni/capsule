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
            for key in [PadKey.l, PadKey.r] {
                if let label = button(key) {
                    label.isHidden = !showsShoulders
                    glass(for: label)?.isHidden = !showsShoulders
                }
            }
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
                item.view.isHidden = !(isDS && showsShortcuts)
                glass(for: item.view)?.isHidden = item.view.isHidden
            }
            setNeedsLayout()
        }
    }

    /// Width / height of the game picture. Sideways, when it leaves black bands on both
    /// sides (a DS game: 4:3 on a long phone), the controls move into them, off the game.
    var pictureAspect: CGFloat = 1.5 {
        didSet {
            if abs(pictureAspect - oldValue) > 0.001 {
                setNeedsLayout()
            }
        }
    }

    private static let shortcuts: [(String, UInt32)] = [
        ("COMPAGNON", PadKey.l2),
        ("MENU", PadKey.select | PadKey.l2),
        ("ÉCRANS", PadKey.r2),
        ("TACTILE", PadKey.select | PadKey.r2),
    ]

    /// Upright with the side wheel, the DS shortcuts are on the wheel and leave the pad.
    var showsShortcuts = true {
        didSet {
            guard showsShortcuts != oldValue else { return }
            for item in buttons where item.isShortcut {
                item.view.isHidden = !(isDS && showsShortcuts)
                glass(for: item.view)?.isHidden = item.view.isHidden
            }
            setNeedsLayout()
        }
    }

    private var buttons: [PadButton] = []
    private let dpad = UIView()
    /// Liquid Glass behind each button (iOS 26; a dark blur before), kept beside its label.
    private var glassViews: [ObjectIdentifier: UIVisualEffectView] = [:]
    private let dpadGlass = PadView.makeGlass()
    private let dpadThumb = UIView()
    private var chevrons: [UIImageView] = []
    private var activeTouches = Set<UITouch>()
    private var currentKeys: UInt32 = 0
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    /// A pane of Liquid Glass (iOS 26), else a dark blur with a light rim; a white sheen
    /// inside it (tag 7) lights up while pressed.
    static func makeGlass() -> UIVisualEffectView {
        let view: UIVisualEffectView
        if #available(iOS 26.0, *) {
            view = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
            view.layer.borderWidth = 1
            view.layer.borderColor = UIColor(white: 1, alpha: 0.35).cgColor
        }
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        let sheen = UIView()
        sheen.backgroundColor = .white
        sheen.alpha = 0
        sheen.tag = 7
        sheen.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.contentView.addSubview(sheen)
        return view
    }

    private func glass(for label: UILabel) -> UIVisualEffectView? {
        glassViews[ObjectIdentifier(label)]
    }

    private func addGlass(under label: UILabel) {
        let pane = Self.makeGlass()
        pane.isHidden = label.isHidden
        insertSubview(pane, belowSubview: label)
        glassViews[ObjectIdentifier(label)] = pane
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
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        // The D-pad: a round pane of glass, a chevron each way and a lit dot that leans
        // towards the direction held.
        dpad.isUserInteractionEnabled = false
        dpad.addSubview(dpadGlass)
        for name in ["chevron.up", "chevron.right", "chevron.down", "chevron.left"] {
            let chevron = UIImageView(image: UIImage(systemName: name,
                                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)))
            chevron.tintColor = UIColor(white: 1, alpha: 0.75)
            chevron.contentMode = .center
            dpad.addSubview(chevron)
            chevrons.append(chevron)
        }
        dpadThumb.backgroundColor = UIColor(white: 1, alpha: 0.9)
        dpadThumb.isUserInteractionEnabled = false
        dpadThumb.layer.shadowColor = UIColor.white.cgColor
        dpadThumb.layer.shadowOpacity = 0.7
        dpadThumb.layer.shadowRadius = 8
        dpadThumb.layer.shadowOffset = .zero
        dpad.addSubview(dpadThumb)
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
            label.textColor = UIColor(white: 1.0, alpha: 0.92)
            label.font = .systemFont(ofSize: title.count > 1 ? 11 : 22, weight: title.count > 1 ? .semibold : .bold)
            label.backgroundColor = .clear
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.35
            label.layer.shadowRadius = 2
            label.layer.shadowOffset = CGSize(width: 0, height: 1)
            label.isUserInteractionEnabled = false
            label.isAccessibilityElement = true
            label.accessibilityTraits = .button
            addSubview(label)
            addGlass(under: label)
            buttons.append(PadButton(key: key, view: label))
        }
        for (title, key) in Self.shortcuts {
            let label = UILabel()
            label.text = title
            label.textAlignment = .center
            label.textColor = UIColor(white: 1.0, alpha: 0.92)
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
            label.backgroundColor = .clear
            label.isUserInteractionEnabled = false
            label.isAccessibilityElement = true
            label.accessibilityTraits = .button
            label.isHidden = true
            addSubview(label)
            addGlass(under: label)
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
        defer {
            for item in buttons {
                guard let pane = glass(for: item.view) else { continue }
                pane.bounds = item.view.bounds
                pane.center = item.view.center
                pane.layer.cornerRadius = item.view.bounds.height / 2
            }
            layoutDpad()
        }
        if width > height {
            let side = (width - min(width, height * pictureAspect)) / 2
            if side >= 120 {
                layoutInBands(side: side)
                return
            }
        }

        // Held sideways the pad lies over the game; upright it has a zone of its own, its top
        // row shared with the toolbar (in the middle, between L and R).
        let landscape = width > height
        let shoulder = landscape ? CGSize(width: 84, height: 38) : CGSize(width: 70, height: 34)
        let top: CGFloat = landscape ? 12 : 10
        button(PadKey.l)?.frame = CGRect(x: 16, y: top, width: shoulder.width, height: shoulder.height)
        button(PadKey.r)?.frame = CGRect(x: width - 16 - shoulder.width, y: top, width: shoulder.width, height: shoulder.height)

        let pill = CGSize(width: 76, height: 30)
        let bottom = height - pill.height - (landscape ? 18 : 10)

        // DS: the shortcut row sits just above START / SELECT, off the picture's middle.
        var lowest = bottom
        if isDS && showsShortcuts {
            let count = CGFloat(Self.shortcuts.count)
            let spacing: CGFloat = 6
            let rowHeight: CGFloat = 28
            let available = landscape ? min(width * 0.5, 380) : width - 32
            let left = (width - available) / 2
            let y = bottom - rowHeight - 8
            let pillWidth = max((available - spacing * (count - 1)) / count, 40)
            for (index, item) in Self.shortcuts.enumerated() {
                shortcut(item.0)?.frame = CGRect(x: left + CGFloat(index) * (pillWidth + spacing), y: y,
                                                 width: pillWidth, height: rowHeight)
            }
            lowest = y
        }
        button(PadKey.select)?.frame = CGRect(x: width / 2 - pill.width - 10, y: bottom, width: pill.width, height: pill.height)
        button(PadKey.start)?.frame = CGRect(x: width / 2 + 10, y: bottom, width: pill.width, height: pill.height)

        // The main cluster sits between the shoulder row and the bottom rows.
        let clusterTop = top + shoulder.height + 10
        let clusterHeight = max((landscape ? bottom : lowest) - 10 - clusterTop, 80)
        let centerY = clusterTop + clusterHeight / 2

        let dpadSize = min(width * 0.42, clusterHeight, 170)
        dpad.frame = CGRect(x: 20, y: centerY - dpadSize / 2, width: dpadSize, height: dpadSize)

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

    }

    /// Sideways beside a narrower picture: the left band holds L, the D-pad, SELECT (and on a
    /// DS COMPAGNON and MENU), the right one R, the face buttons, START (ÉCRANS, TACTILE).
    private func layoutInBands(side: CGFloat) {
        let width = bounds.width
        let height = bounds.height
        // Off the rounded corners and the camera, and a little over the picture's own edge.
        let inset = max(safeAreaInsets.left, safeAreaInsets.right)
        let overlap: CGFloat = 14
        let margin: CGFloat = 4
        let column = side - inset + overlap - 2 * margin
        let leftX = inset + margin
        let rightX = width - side - overlap + margin
        let shoulder = CGSize(width: min(column, 96), height: 36)
        let top: CGFloat = 10
        button(PadKey.l)?.frame = CGRect(x: leftX + (column - shoulder.width) / 2, y: top,
                                         width: shoulder.width, height: shoulder.height)
        button(PadKey.r)?.frame = CGRect(x: rightX + (column - shoulder.width) / 2, y: top,
                                         width: shoulder.width, height: shoulder.height)

        // The bottom of each band: SELECT / START, and the DS shortcuts above them.
        let pillHeight: CGFloat = 28
        let pillWidth = min(column, 100)
        let startY = height - pillHeight - 14
        button(PadKey.select)?.frame = CGRect(x: leftX + (column - pillWidth) / 2, y: startY,
                                              width: pillWidth, height: pillHeight)
        button(PadKey.start)?.frame = CGRect(x: rightX + (column - pillWidth) / 2, y: startY,
                                             width: pillWidth, height: pillHeight)
        var lowest = startY
        if isDS {
            let rowHeight: CGFloat = 26
            let leftItems = [Self.shortcuts[0].0, Self.shortcuts[1].0]
            let rightItems = [Self.shortcuts[2].0, Self.shortcuts[3].0]
            for (row, title) in leftItems.reversed().enumerated() {
                shortcut(title)?.frame = CGRect(x: leftX + (column - pillWidth) / 2,
                                                y: startY - CGFloat(row + 1) * (rowHeight + 6),
                                                width: pillWidth, height: rowHeight)
            }
            for (row, title) in rightItems.reversed().enumerated() {
                shortcut(title)?.frame = CGRect(x: rightX + (column - pillWidth) / 2,
                                                y: startY - CGFloat(row + 1) * (rowHeight + 6),
                                                width: pillWidth, height: rowHeight)
            }
            lowest = startY - 2 * (rowHeight + 6)
        }

        // The D-pad and the face buttons in the room left between the shoulders and the bottom rows.
        let clusterTop = top + shoulder.height + 8
        let clusterHeight = max(lowest - 8 - clusterTop, 80)
        let centerY = clusterTop + clusterHeight / 2

        let dpadSize = min(column, clusterHeight, 160)
        dpad.frame = CGRect(x: leftX + (column - dpadSize) / 2, y: centerY - dpadSize / 2, width: dpadSize, height: dpadSize)

        let diameter = min(column / 2.9, clusterHeight / 2.9, 58)
        let gap = diameter * 0.95
        let center = CGPoint(x: rightX + column / 2, y: centerY)
        let places: [(UInt32, CGPoint)] = [
            (PadKey.x, CGPoint(x: center.x, y: center.y - gap)),
            (PadKey.a, CGPoint(x: center.x + gap, y: center.y)),
            (PadKey.b, CGPoint(x: center.x, y: center.y + gap)),
            (PadKey.y, CGPoint(x: center.x - gap, y: center.y)),
        ]
        for (key, point) in places {
            button(key)?.frame = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
        }
    }

    /// The D-pad's glass, chevrons and dot, for its frame and the direction held.
    private func layoutDpad(animated: Bool = false) {
        let size = dpad.bounds.width
        guard size > 0 else { return }
        dpadGlass.frame = dpad.bounds
        dpadGlass.layer.cornerRadius = size / 2
        let reach = size * 0.36
        let places = [CGPoint(x: size / 2, y: size / 2 - reach), CGPoint(x: size / 2 + reach, y: size / 2),
                      CGPoint(x: size / 2, y: size / 2 + reach), CGPoint(x: size / 2 - reach, y: size / 2)]
        let held = [PadKey.up, PadKey.right, PadKey.down, PadKey.left]
        for (index, chevron) in chevrons.enumerated() {
            chevron.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
            chevron.center = places[index]
            chevron.tintColor = UIColor(white: 1, alpha: currentKeys & held[index] != 0 ? 1 : 0.6)
        }
        var lean = CGPoint.zero
        if currentKeys & PadKey.left != 0 { lean.x -= 1 }
        if currentKeys & PadKey.right != 0 { lean.x += 1 }
        if currentKeys & PadKey.up != 0 { lean.y -= 1 }
        if currentKeys & PadKey.down != 0 { lean.y += 1 }
        let pressed = lean != .zero
        let side: CGFloat = pressed ? 22 : 14
        let change = {
            self.dpadThumb.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            self.dpadThumb.layer.cornerRadius = side / 2
            self.dpadThumb.center = CGPoint(x: size / 2 + lean.x * size * 0.2, y: size / 2 + lean.y * size * 0.2)
            self.dpadThumb.alpha = pressed ? 1 : 0.55
        }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.4,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: change)
        } else {
            change()
        }
    }

    /// Pressed: squeezed, its glass lit; let go: springs back past its size.
    private func setPressed(_ label: UILabel, _ down: Bool) {
        let pane = glass(for: label)
        let sheen = pane?.contentView.viewWithTag(7)
        let transform = down ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity
        if down {
            UIView.animate(withDuration: 0.1, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                label.transform = transform
                pane?.transform = transform
                sheen?.alpha = 0.28
            }
        } else {
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.45, initialSpringVelocity: 0.8,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                label.transform = transform
                pane?.transform = transform
                sheen?.alpha = 0
            }
        }
    }

    // MARK: - Touches

    /// Only the controls take touches: everywhere else they reach the game underneath
    /// (its touch screen, PokeDaisy's companion and HUD), which matters when the pad lies over it.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if dpad.frame.insetBy(dx: -18, dy: -18).contains(point) {
            return true
        }
        return buttons.contains { !$0.view.isHidden && $0.view.frame.insetBy(dx: -12, dy: -12).contains(point) }
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
        let before = currentKeys
        currentKeys = keys
        for item in buttons {
            let down = item.isShortcut ? keys & item.key == item.key : keys & item.key != 0
            let was = item.isShortcut ? before & item.key == item.key : before & item.key != 0
            if down != was {
                setPressed(item.view, down)
            }
        }
        let directions = PadKey.up | PadKey.down | PadKey.left | PadKey.right
        if keys & directions != before & directions {
            layoutDpad(animated: true)
        }
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
    var pictureAspect: CGFloat = 1.5
    var showsShortcuts = true
    let onKeys: (UInt32) -> Void

    func makeUIView(context: Context) -> PadView {
        let view = PadView()
        view.onKeys = onKeys
        view.showsShoulders = showsShoulders
        view.showsShortcuts = showsShortcuts
        view.isDS = isDS
        view.pictureAspect = pictureAspect
        return view
    }

    func updateUIView(_ uiView: PadView, context: Context) {
        uiView.onKeys = onKeys
        uiView.showsShoulders = showsShoulders
        uiView.showsShortcuts = showsShortcuts
        uiView.isDS = isDS
        uiView.pictureAspect = pictureAspect
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
    /// Called when the view comes on screen: the frames go to the one shown. When the layout
    /// changes (upright to sideways) SwiftUI builds the new view before it drops the old one,
    /// and the old one kept the frames: a black game.
    var onShown: ((ScreenUIView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            onShown?(self)
        }
    }
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
        view.onShown = { [weak session] shown in
            session?.displayLayer = shown.layer
        }
        view.onTouch = { [weak session] point in
            session?.setTouch(point)
        }
        return view
    }

    func updateUIView(_ uiView: ScreenUIView, context: Context) {
        if uiView.window != nil {
            session.displayLayer = uiView.layer
        }
    }

    static func dismantleUIView(_ uiView: ScreenUIView, coordinator: ()) {
        uiView.onShown = nil
    }
}
