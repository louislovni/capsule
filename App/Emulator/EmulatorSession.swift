import Combine
import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI
import UIKit

/// Buttons, as the libretro core expects them (bits of RETRO_DEVICE_ID_JOYPAD_*).
/// A colour, 0...1 each.
struct Tint: Equatable {
    var r: Double
    var g: Double
    var b: Double

    static let standard = Tint(r: 0.62, g: 0.79, b: 0.65)
}

final class PictureTint: ObservableObject {
    @Published var value = Tint.standard
}

enum PadKey {
    static let b: UInt32 = 1 << 0
    static let y: UInt32 = 1 << 1
    static let select: UInt32 = 1 << 2
    static let start: UInt32 = 1 << 3
    static let up: UInt32 = 1 << 4
    static let down: UInt32 = 1 << 5
    static let left: UInt32 = 1 << 6
    static let right: UInt32 = 1 << 7
    static let a: UInt32 = 1 << 8
    static let x: UInt32 = 1 << 9
    static let l: UInt32 = 1 << 10
    static let r: UInt32 = 1 << 11
    static let l2: UInt32 = 1 << 12
    static let r2: UInt32 = 1 << 13
}

/// Owns the PokeDaisy core and the thread that runs it.
///
/// The core draws the game and PokeDaisy's companion, HUD and quick menu into
/// one frame; this class feeds it buttons and touches and shows what it draws.
/// Every call into the core happens on the emulation thread: the interface
/// queues work for it with `perform`.
final class EmulatorSession: ObservableObject {
    static let speeds = [1, 2, 4]

    @Published private(set) var speed = 1
    @Published private(set) var isPaused = false
    @Published private(set) var loadFailed = false
    /// The technical reason a game could not start, shown under the message.
    @Published private(set) var loadError = ""
    /// Width / height of the frame the core draws (it changes with EXPAND and the companion).
    @Published private(set) var screenAspect: CGFloat = 1.5
    @Published var notice: String?
    /// The picture's average colour, refreshed about every second: the Capsule controller takes
    /// its tint from it. An object of its own, so that only the views painted with it redraw (a
    /// change here used to rebuild the whole game screen, an open menu included, every second).
    let pictureTint = PictureTint()
    /// What PokeDaisy made of the game when it loaded (shown once, then kept in the menu).
    @Published private(set) var companionInfo: String?
    @Published private(set) var companionSupported = true
    /// PokeDaisy's menus (ÉQUIPE, DEX, CARTE, SAC, GUIDE, réglages) can open in the panel over the controls (its GBA core).
    @Published private(set) var dockAvailable = false
    /// The panel is open (asked by the handle, or opened / closed by the core itself: a HUD tap, B on its first page).
    @Published private(set) var dockOpen = false
    /// The layer the panel's pixels go to. Set by the panel's view.
    weak var dockLayer: CALayer?

    /// Sideways or upright: the GBA core lays its picture out for the matching panel.
    private(set) var landscape = false

    let game: Game
    /// The view frames are drawn into. Set by the screen view.
    weak var screenView: ScreenUIView?

    private var core: OpaquePointer?
    private var thread: Thread?
    private let audio = AudioOutput()
    private let finished = DispatchSemaphore(value: 0)
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    // Shared with the emulation thread, under `lock`.
    private let lock = NSLock()
    private var alive = false
    private var pausedFlag = false
    private var speedFlag = 1
    private var pending: [(OpaquePointer) -> Void] = []

    /// Where the core keeps its own files (the companion's settings).
    static let dataDirectory = Storage.documents.appendingPathComponent("PokeDaisy", isDirectory: true)

    /// A fixed panel set by hand (UserDefaults "pokedaisyPanel"), or nil to follow the phone.
    private static var panelOverride: String? {
        UserDefaults.standard.string(forKey: "pokedaisyPanel")
    }

    /// Upright, the part of the screen the picture gets (above the controls), in pixels; nil
    /// for the whole screen.
    private(set) var pictureArea: CGSize?
    /// Upright, the whole screen's height (pixels): a DS game's picture runs on under the
    /// controls ("WxH:V", V the clear part on top). Not a GBA one's: its HUD keeps to its panel.
    private(set) var screenHeight: CGFloat?
    /// Upright, a GBA / Game Boy game's canvas runs on under the controls too: PokeDaisy is told a
    /// panel taller than the screen, whose middle (where it puts the game) is just above the
    /// controls, and the rows its HUD keeps to (the part clear of the status bar and controls).
    /// The frontend shows its bottom part, down to the screen's bottom edge. Pixels.
    var tallCanvas: (height: CGFloat, hudTop: CGFloat, hudBottom: CGFloat)? {
        guard !game.isDS, !landscape, let area = pictureArea, let full = screenHeight, full > area.height + 1 else {
            return nil
        }
        let isGBA = game.romURL.pathExtension.lowercased() == "gba"
        let gameW: CGFloat = isGBA ? 240 : 160, gameH: CGFloat = isGBA ? 160 : 144
        let scale = max(floor(area.width / gameW), 1)
        // The game's screen down against the controls (its text box just above L and R), not
        // above the status bar.
        let half = gameH * scale / 2
        let middle = max(area.height - half - 4 * scale, topInset + half)
        let height = 2 * (full - middle)
        let hidden = height - full
        // The HUD (the minimap on the top right) a little into the status bar's band: it's hidden in game, and the
        // Dynamic Island keeps to the middle.
        let hudTop = max(topInset - 20 * UIScreen.main.scale, 10 * UIScreen.main.scale)
        return (height, hudTop + hidden, area.height + hidden)
    }

    /// Upright, the status bar's height (pixels): the HUD starts below it.
    private(set) var topInset: CGFloat = 0

    /// The screen size the core is told about: it places its picture and companion to fit.
    var panel: String {
        if let fixed = Self.panelOverride {
            return fixed
        }
        if !landscape, let area = pictureArea, area.width >= 1, area.height >= 1 {
            if let tall = tallCanvas {
                return "\(Int(area.width.rounded()))x\(Int(tall.height.rounded())):\(Int(tall.hudTop.rounded())):\(Int(tall.hudBottom.rounded()))"
            }
            if game.isDS, let full = screenHeight, full > area.height + 1 {
                return "\(Int(area.width.rounded()))x\(Int(full.rounded())):\(Int(area.height.rounded())):\(Int(topInset.rounded()))"
            }
            return "\(Int(area.width.rounded()))x\(Int(area.height.rounded()))"
        }
        return Orientation.panel(landscape: landscape)
    }

    /// PokeDaisy's companion settings start with EXPAND (the map drawn to the edges of
    /// a wide screen, as on Android) rather than the game's bare picture. Only when
    /// there are no settings yet: a choice made in the companion stays.
    static func prepareCompanionSettings() {
        let folder = dataDirectory.appendingPathComponent("pokedaisy", isDirectory: true)
        let file = folder.appendingPathComponent("settings.ini")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("aspect=1\n".utf8).write(to: file)
    }

    /// The phone turned (or the plein écran button turned it).
    func setLandscape(_ value: Bool) {
        guard value != landscape else { return }
        landscape = value
        sendPanel()
    }

    /// Upright, the room the picture has above the controls (points): EXPAND fills it, and
    /// PokeDaisy keeps its HUD inside it, clear of the controls.
    func setPictureArea(_ points: CGSize?, screenHeight fullPoints: CGFloat? = nil, topInset insetPoints: CGFloat = 0) {
        let scale = UIScreen.main.scale
        topInset = insetPoints * scale
        let area = points.map { CGSize(width: $0.width * scale, height: $0.height * scale) }
        let full = fullPoints.map { $0 * scale }
        if let old = pictureArea, let new = area,
           abs(old.width - new.width) < 2, abs(old.height - new.height) < 2,
           abs((screenHeight ?? 0) - (full ?? 0)) < 2 {
            return
        }
        pictureArea = area
        screenHeight = full
        if !landscape {
            sendPanel()
        }
    }

    private func sendPanel() {
        guard Self.panelOverride == nil, core != nil else { return }
        let panel = self.panel
        perform { core in
            lr_set_panel(core, panel)
        }
    }

    init(game: Game) {
        self.game = game
    }

    // MARK: - Lifecycle (main thread)

    func start(landscape: Bool, pictureArea: CGSize? = nil, screenHeight fullPoints: CGFloat? = nil, topInset insetPoints: CGFloat = 0) {
        guard thread == nil, !loadFailed else { return }
        self.landscape = landscape
        if let points = pictureArea {
            let scale = UIScreen.main.scale
            self.pictureArea = CGSize(width: points.width * scale, height: points.height * scale)
            self.screenHeight = fullPoints.map { $0 * scale }
            self.topInset = insetPoints * scale
        }
        Storage.prepare()
        try? FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true)
        guard let coreURL = game.coreURL else {
            loadError = "Frameworks folder missing from the app"
            loadFailed = true
            return
        }
        let logMark = CoreLog.mark()
        guard let created = lr_create(coreURL.path, game.romURL.path, game.saveURL.path, Self.dataDirectory.path, panel) else {
            loadError = String(cString: lr_last_error())
            loadFailed = true
            return
        }
        if let status = CoreLog.companionStatus(lines: CoreLog.lines(since: logMark), isDS: game.isDS) {
            companionInfo = status.text
            companionSupported = status.supported
            notice = status.text
        }
        core = created
        alive = true
        updateAspect(width: lr_video_width(created), height: lr_video_height(created))

        audio.start(core: created)
        // PokeDaisy's menus in French on a French phone (English otherwise).
        let french = Locale.preferredLanguages.first?.hasPrefix("fr") ?? false
        lr_set_language(created, french ? "fr" : "en")
        dockAvailable = lr_dock_available(created)
        dockAvailableOnThread = dockAvailable
        if dockAvailable {
            // Docked from the start: the HUD's taps and the companion button open the panel, not the menus over the game.
            lr_dock(created, dockSize.width, dockSize.height)
        }
        if !game.isDS {
            coopReady = lr_coop_available(created)
            if coopReady {
                CoopService.shared.gameStarted(game)
            }
        }
        let worker = Thread { [self] in
            self.runLoop(created)
        }
        worker.name = "Capsule emulation"
        worker.qualityOfService = .userInteractive
        thread = worker
        worker.start()
    }

    /// Stops the game and waits until the battery save is written.
    func stop() {
        guard thread != nil else { return }
        audio.stop()
        lock.lock()
        alive = false
        lock.unlock()
        finished.wait()
        thread = nil
        core = nil
    }

    // MARK: - Controls (main thread)

    private var touchKeys: UInt32 = 0
    private var controllerKeys: UInt32 = 0

    /// The on-screen buttons held.
    func setKeys(_ keys: UInt32) {
        touchKeys = keys
        sendKeys()
    }

    /// A Bluetooth controller's buttons held (added to the on-screen ones).
    func setControllerKeys(_ keys: UInt32) {
        controllerKeys = keys
        sendKeys()
    }

    private var pulseKeys: UInt32 = 0

    /// Holds these keys for a short moment, as a tap would (PokeDaisy's DS shortcuts).
    func pulse(_ keys: UInt32) {
        pulseKeys = keys
        sendKeys()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.pulseKeys == keys else { return }
            self.pulseKeys = 0
            self.sendKeys()
        }
    }

    private func sendKeys() {
        guard let core = core else { return }
        lr_set_keys(core, touchKeys | controllerKeys | pulseKeys)
    }

    /// A touch on the frame, in its own coordinates (0...1 on both axes), or nil when lifted.
    func setTouch(_ point: CGPoint?) {
        guard let core = core else { return }
        if let point = point {
            let x = Int32((point.x * 2 - 1) * 32767)
            let y = Int32((point.y * 2 - 1) * 32767)
            lr_set_pointer(core, true, x, y)
        } else {
            lr_set_pointer(core, false, 0, 0)
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        lock.lock()
        pausedFlag = paused
        lock.unlock()
        if paused {
            audio.pause()
            perform { core in
                lr_flush_save(core)
            }
        } else {
            audio.resume()
        }
    }

    func cycleSpeed() {
        let index = Self.speeds.firstIndex(of: speed) ?? 0
        setSpeed(Self.speeds[(index + 1) % Self.speeds.count])
    }

    func setSpeed(_ next: Int) {
        speed = next
        lock.lock()
        speedFlag = next
        lock.unlock()
    }

    func reset() {
        perform { core in
            lr_reset(core)
        }
    }

    func saveState(slot: Int) {
        let path = game.stateURL(slot: slot).path
        perform { [weak self] core in
            let ok = lr_save_state(core, path)
            DispatchQueue.main.async {
                self?.notice = ok ? "État \(slot) enregistré" : "Impossible d'enregistrer l'état \(slot)"
            }
        }
    }

    func loadState(slot: Int) {
        let path = game.stateURL(slot: slot).path
        perform { [weak self] core in
            let ok = lr_load_state(core, path)
            DispatchQueue.main.async {
                self?.notice = ok ? "État \(slot) chargé" : "Aucun état \(slot) à charger"
            }
        }
    }

    // MARK: - The panel (main thread)

    /// Its canvas: 320 companion pixels across, as tall as the panel's shape asks (240 to 480).
    static func dockCanvas(for points: CGSize) -> (width: Int32, height: Int32) {
        guard points.width > 1, points.height > 1 else { return (320, 360) }
        let height = Int32((320 * points.height / points.width).rounded())
        return (320, min(max(height, 240), 480))
    }

    private var dockSize: (width: Int32, height: Int32) = (320, 360)

    /// The panel's size in points: its canvas follows.
    func setDockSize(_ points: CGSize) {
        let size = Self.dockCanvas(for: points)
        guard size != dockSize else { return }
        dockSize = size
        perform { core in
            lr_dock(core, size.width, size.height)
        }
    }

    /// Opens or closes the panel.
    func setDock(open: Bool) {
        guard dockAvailable, open != dockOpen else { return }
        dockOpen = open
        let size = dockSize
        perform { [weak self] core in
            lr_dock(core, size.width, size.height)
            lr_dock_open(core, open)
            self?.dockAsked = open
        }
    }

    /// The finger on the panel, 0...1 on both axes, down while held.
    func dockTouch(_ point: CGPoint, down: Bool) {
        let size = dockSize
        let x = Int32((point.x * CGFloat(size.width)).rounded(.down))
        let y = Int32((point.y * CGFloat(size.height)).rounded(.down))
        perform { core in
            lr_dock_touch(core, x, y, down)
        }
    }

    private func perform(_ body: @escaping (OpaquePointer) -> Void) {
        lock.lock()
        pending.append(body)
        lock.unlock()
    }

    private func updateAspect(width: UInt32, height: UInt32) {
        guard width > 0, height > 0 else { return }
        let aspect = CGFloat(width) / CGFloat(height)
        if abs(aspect - screenAspect) > 0.001 {
            screenAspect = aspect
        }
    }

    // MARK: - Emulation thread

    private func runLoop(_ core: OpaquePointer) {
        let frameTime = 1.0 / lr_frame_rate(core)
        let audioTarget = Int(lr_audio_rate(core)) / 20 // keep about 50 ms queued
        let saveInterval = 120 // frames: the battery save is written within ~2 s of a change
        var deadline = CACurrentMediaTime()
        var frameCount = 0

        while true {
            lock.lock()
            let keepGoing = alive
            let paused = pausedFlag
            let speed = speedFlag
            let work = pending
            pending.removeAll()
            lock.unlock()

            if !keepGoing {
                break
            }
            for body in work {
                body(core)
            }
            if paused {
                Thread.sleep(forTimeInterval: 0.02)
                deadline = CACurrentMediaTime()
                continue
            }

            let coop = coopReady && CoopService.shared.isLinked
            for _ in 0..<speed {
                lr_run_frame(core, speed > 1)
                if coop {
                    coopFrame(core)
                }
            }
            if coopWasLinked && !coop {
                lr_coop_stop(core) // the partner goes from the map with the link
            }
            coopWasLinked = coop
            present(core)
            if dockAvailableOnThread {
                presentDock(core)
            }
            if frameCount % 30 == 0 {
                coopNotice()
            }

            frameCount += 1
            if frameCount % saveInterval == 0 {
                let before = Storage.modificationDate(of: game.saveURL)
                if !lr_flush_save(core) {
                    DispatchQueue.main.async { [weak self] in
                        self?.notice = "La sauvegarde n'a pas pu être écrite"
                    }
                } else if Storage.modificationDate(of: game.saveURL) != before {
                    // The game saved: keep it among its save points, and send it to the cloud.
                    SaveHistory.record(game)
                    let file = game.saveURL.lastPathComponent
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: CloudSync.saveWritten, object: file)
                    }
                }
            }

            // Pace on the clock, nudged by how much audio is waiting, so sound
            // neither starves nor piles up.
            let queued = Int(lr_audio_queued(core))
            let correction = speed > 1 ? 1.0 : (queued > audioTarget ? 1.004 : 0.996)
            deadline += frameTime * correction
            let now = CACurrentMediaTime()
            if deadline > now {
                Thread.sleep(forTimeInterval: deadline - now)
            } else if now - deadline > 0.25 {
                deadline = now // fell far behind (app was suspended): start over
            }
        }

        if !game.isDS {
            CoopService.shared.gameStopped()
        }
        lr_destroy(core) // writes the battery save
        finished.signal()
    }

    // MARK: - The panel (the emulation thread)

    private var dockAvailableOnThread = false
    /// What the thread last asked or saw: the core opening or closing it by itself is told to the main thread.
    private var dockAsked = false
    private var dockSerial: UInt32 = 0
    private let dockColorSpace = CGColorSpaceCreateDeviceRGB()

    private func presentDock(_ core: OpaquePointer) {
        let open = lr_dock_is_open(core)
        if open != dockAsked {
            dockAsked = open
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.dockOpen != open else { return }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                    self.dockOpen = open
                }
            }
        }
        guard open else { return }
        var width: Int32 = 0, height: Int32 = 0, serial: UInt32 = 0
        guard let pixels = lr_dock_pixels(core, &width, &height, &serial), width > 0, height > 0, serial != dockSerial else {
            return
        }
        dockSerial = serial
        let data = Data(bytes: pixels, count: Int(width) * Int(height) * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: Int(width),
                  height: Int(height),
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: Int(width) * 4,
                  space: dockColorSpace,
                  // 0x00RRGGBB words, little-endian: B, G, R, unused.
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let layer = self?.dockLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = image
            CATransaction.commit()
        }
    }

    // MARK: - Co-op (the emulation thread)

    /// The game can show a co-op partner (PokeDaisy's core: Emerald), worked out once it runs.
    private var coopReady = false
    private var coopWasLinked = false
    private var coopLastState = Int32(COOP_LINK_OFF)

    /// One frame of co-op presence: the partner's updates into the core, the player's out of it.
    private func coopFrame(_ core: OpaquePointer) {
        let now = UInt32(truncatingIfNeeded: CoopService.now)
        for message in CoopService.shared.takePresence() {
            message.withUnsafeBufferPointer { lr_coop_receive(core, $0.baseAddress, $0.count, now) }
        }
        var out = [UInt8](repeating: 0, count: Int(LR_COOP_PRESENCE_SIZE))
        if lr_coop_frame(core, now, &out) {
            CoopService.shared.sendPresence(out)
        }
    }

    /// "<partner> joined you" / "lost": said once each time the link changes.
    private func coopNotice() {
        let service = CoopService.shared
        DispatchQueue.main.async {
            let state = service.linkState
            guard state != self.coopLastState else { return }
            let name = service.linkPartner
            if state == Int32(COOP_LINK_CONNECTED) {
                self.notice = "\(name) joue avec toi"
            } else if self.coopLastState == Int32(COOP_LINK_CONNECTED) {
                self.notice = "Connexion perdue avec \(name)"
            }
            self.coopLastState = state
        }
    }

    private var tintFrames = 0

    /// The mean of a grid of 16 × 16 pixels (RGBX bytes), leaving out near-black ones (the
    /// bands and the DS's gaps), which would only grey the tint.
    private static func averageColour(_ data: Data, width: Int, height: Int) -> Tint {
        var r = 0, g = 0, b = 0, n = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            for j in 0..<16 {
                for i in 0..<16 {
                    let x = (2 * i + 1) * width / 32, y = (2 * j + 1) * height / 32
                    let o = (y * width + x) * 4
                    let pr = Int(bytes[o]), pg = Int(bytes[o + 1]), pb = Int(bytes[o + 2])
                    if pr + pg + pb < 60 { continue }
                    r += pr; g += pg; b += pb; n += 1
                }
            }
        }
        guard n > 0 else { return Tint.standard }
        // Rounded, so that a picture that barely changes doesn't repaint the card.
        func level(_ v: Int) -> Double { (Double(v) / Double(n) / 255 * 32).rounded() / 32 }
        return Tint(r: level(r), g: level(g), b: level(b))
    }

    private func present(_ core: OpaquePointer) {
        guard let pixels = lr_video_buffer(core) else { return }
        let width = Int(lr_video_width(core))
        let height = Int(lr_video_height(core))
        guard width > 0, height > 0 else { return }
        let data = Data(bytes: pixels, count: width * height * 4)
        tintFrames += 1
        if tintFrames % 60 == 1 {
            let tint = Self.averageColour(data, width: width, height: height)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.pictureTint.value != tint else { return }
                self.pictureTint.value = tint
            }
        }
        var values = [Int32](repeating: 0, count: Int(LR_SCENE_VALUES))
        let count = lr_scene(core, &values, Int32(values.count))
        let scene = count >= Int32(LR_SCENE_VALUES) ? SceneInfo(values: values) : SceneInfo()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateAspect(width: UInt32(width), height: UInt32(height))
            self.screenView?.show(data, width: width, height: height, scene: scene)
        }
    }
}
