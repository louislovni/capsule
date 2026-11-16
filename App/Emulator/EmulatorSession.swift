import Combine
import CoreGraphics
import Foundation
import QuartzCore

/// Buttons, as the libretro core expects them (bits of RETRO_DEVICE_ID_JOYPAD_*).
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

    let game: Game
    /// The layer frames are drawn into. Set by the screen view.
    weak var displayLayer: CALayer?

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

    /// The screen size the core is told about: it places its companion to fit.
    static var panel: String {
        UserDefaults.standard.string(forKey: "pokedaisyPanel") ?? "auto"
    }

    init(game: Game) {
        self.game = game
    }

    // MARK: - Lifecycle (main thread)

    func start() {
        guard thread == nil, !loadFailed else { return }
        Storage.prepare()
        try? FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true)
        guard let coreURL = game.coreURL else {
            loadError = "Frameworks folder missing from the app"
            loadFailed = true
            return
        }
        guard let created = lr_create(coreURL.path, game.romURL.path, game.saveURL.path, Self.dataDirectory.path, Self.panel) else {
            loadError = String(cString: lr_last_error())
            loadFailed = true
            return
        }
        core = created
        alive = true
        updateAspect(width: lr_video_width(created), height: lr_video_height(created))

        audio.start(core: created)
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

    func setKeys(_ keys: UInt32) {
        guard let core = core else { return }
        lr_set_keys(core, keys)
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
        let next = Self.speeds[(index + 1) % Self.speeds.count]
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

            for _ in 0..<speed {
                lr_run_frame(core, speed > 1)
            }
            present(core)

            frameCount += 1
            if frameCount % saveInterval == 0 && !lr_flush_save(core) {
                DispatchQueue.main.async { [weak self] in
                    self?.notice = "La sauvegarde n'a pas pu être écrite"
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

        lr_destroy(core) // writes the battery save
        finished.signal()
    }

    private func present(_ core: OpaquePointer) {
        guard let pixels = lr_video_buffer(core) else { return }
        let width = Int(lr_video_width(core))
        let height = Int(lr_video_height(core))
        guard width > 0, height > 0 else { return }
        let data = Data(bytes: pixels, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateAspect(width: UInt32(width), height: UInt32(height))
            guard let layer = self.displayLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = image
            CATransaction.commit()
        }
    }
}
