import Combine
import CoreGraphics
import Foundation
import QuartzCore

/// One member of the team, as shown by the companion panel.
struct PartyMember: Identifiable, Equatable {
    let id: Int
    let speciesName: String
    let summary: MonSummary
    let moveNames: [String]
    /// The 100 bytes as they are in the game's memory.
    let raw: Data
}

/// GBA key bits, as mGBA expects them.
enum GBAKey {
    static let a: UInt32 = 1 << 0
    static let b: UInt32 = 1 << 1
    static let select: UInt32 = 1 << 2
    static let start: UInt32 = 1 << 3
    static let right: UInt32 = 1 << 4
    static let left: UInt32 = 1 << 5
    static let up: UInt32 = 1 << 6
    static let down: UInt32 = 1 << 7
    static let r: UInt32 = 1 << 8
    static let l: UInt32 = 1 << 9
}

/// Owns the emulator core and the thread that runs it.
///
/// Every call into the core happens on the emulation thread. The interface asks
/// for things with `perform`, which queues a block for that thread.
final class EmulatorSession: ObservableObject {
    static let speeds = [1, 2, 4]

    @Published private(set) var party: [PartyMember] = []
    @Published private(set) var speed = 1
    @Published private(set) var isPaused = false
    @Published private(set) var loadFailed = false
    @Published private(set) var gameLabel = ""
    @Published private(set) var isKnownGame = false
    @Published var notice: String?
    /// Names, base stats and places of this ROM, for the detail sheet.
    @Published private(set) var romData: RomData?

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

    // Only touched on the emulation thread.
    private var profile: PKProfile?
    private var speciesTable = -1
    private var moveTable = -1
    private var scannedParty: UInt32?
    private var framesSinceScan = 0

    private static let videoWidth = 240
    private static let videoHeight = 160
    private static let framesPerSecond = 59.7275

    init(game: Game) {
        self.game = game
    }

    // MARK: - Lifecycle (main thread)

    func start() {
        guard thread == nil, !loadFailed else { return }
        Storage.prepare()
        guard let created = emu_create(game.romURL.path, game.saveURL.path) else {
            loadFailed = true
            return
        }
        core = created
        alive = true

        var code = [CChar](repeating: 0, count: 5)
        emu_game_code(created, &code)
        let codeText = String(cString: code)
        let revision = emu_revision(created)
        // `code` is always 5 bytes long, which is what the lookup compares against.
        if let found = pk_profile_find(code, revision) {
            profile = found.pointee
            isKnownGame = true
        }
        gameLabel = codeText

        let romURL = game.romURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = RomData.load(romURL)
            DispatchQueue.main.async {
                self?.romData = data
            }
        }

        audio.start(core: created)
        let worker = Thread { [self] in
            self.runLoop(created)
        }
        worker.name = "Capsule emulation"
        worker.qualityOfService = .userInteractive
        thread = worker
        worker.start()
    }

    /// Stops the game and waits until the save file is flushed and closed.
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
        emu_set_keys(core, keys)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        lock.lock()
        pausedFlag = paused
        lock.unlock()
        if paused {
            audio.pause()
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
            emu_reset(core)
        }
    }

    func saveState(slot: Int) {
        let path = game.stateURL(slot: slot).path
        perform { [weak self] core in
            let ok = emu_save_state(core, path)
            DispatchQueue.main.async {
                self?.notice = ok ? "État \(slot) enregistré" : "Impossible d'enregistrer l'état \(slot)"
            }
        }
    }

    func loadState(slot: Int) {
        let path = game.stateURL(slot: slot).path
        perform { [weak self] core in
            let ok = emu_load_state(core, path)
            DispatchQueue.main.async {
                self?.notice = ok ? "État \(slot) chargé" : "Aucun état \(slot) à charger"
            }
        }
    }

    /// Restores HP and clears status conditions of the whole team.
    /// Outside of battle only: during a fight the game works on its own copies.
    func healParty() {
        perform { [weak self] core in
            guard let self = self else { return }
            let healed = self.healPartyOnThread(core)
            DispatchQueue.main.async {
                self.notice = healed > 0 ? "Équipe soignée" : "Équipe introuvable en mémoire"
            }
        }
    }

    private func perform(_ body: @escaping (OpaquePointer) -> Void) {
        lock.lock()
        pending.append(body)
        lock.unlock()
    }

    // MARK: - Emulation thread

    private func runLoop(_ core: OpaquePointer) {
        locateNameTables(core)

        let frameTime = 1.0 / Self.framesPerSecond
        let audioTarget = Int(emu_audio_rate(core)) / 20 // keep about 50 ms queued
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
                emu_run_frame(core, speed > 1)
            }
            present(core)

            frameCount += 1
            if frameCount % 30 == 0 {
                publishParty(core)
            }

            // Pace on the clock, nudged by how much audio is waiting, so sound
            // neither starves nor piles up.
            let queued = Int(emu_audio_queued(core))
            let correction = speed > 1 ? 1.0 : (queued > audioTarget ? 1.004 : 0.996)
            deadline += frameTime * correction
            let now = CACurrentMediaTime()
            if deadline > now {
                Thread.sleep(forTimeInterval: deadline - now)
            } else if now - deadline > 0.25 {
                deadline = now // fell far behind (app was suspended): start over
            }
        }

        emu_destroy(core)
        finished.signal()
    }

    private func present(_ core: OpaquePointer) {
        guard let pixels = emu_video_buffer(core) else { return }
        let byteCount = Self.videoWidth * Self.videoHeight * 4
        let data = Data(bytes: pixels, count: byteCount)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: Self.videoWidth,
                  height: Self.videoHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: Self.videoWidth * 4,
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
            guard let layer = self?.displayLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = image
            CATransaction.commit()
        }
    }

    private func locateNameTables(_ core: OpaquePointer) {
        var size = 0
        guard let rom = emu_rom_data(core, &size) else { return }
        speciesTable = pk_rom_find_species_names(rom, size)
        moveTable = pk_rom_find_move_names(rom, size)
    }

    /// Address and size of the team in memory, or nil when it cannot be found.
    private func partyLocation(_ core: OpaquePointer) -> (address: UInt32, count: Int)? {
        if let profile = profile {
            var countByte: UInt8 = 0
            emu_read_bytes(core, profile.playerPartyCount, &countByte, 1)
            return (profile.playerParty, min(Int(countByte), 6))
        }

        // Unknown game (hack): look for the team by its shape, and remember where it was.
        if let address = scannedParty {
            var raw = [UInt8](repeating: 0, count: 600)
            emu_read_bytes(core, address, &raw, raw.count)
            var count: Int32 = 0
            let offset = pk_scan_party(raw, raw.count, &count)
            if offset == 0 {
                return (address, Int(count))
            }
            scannedParty = nil
        }
        framesSinceScan += 30
        guard framesSinceScan >= 120 else { return nil }
        framesSinceScan = 0
        for (base, length) in [(UInt32(0x0200_0000), 0x40000), (UInt32(0x0300_0000), 0x8000)] {
            var ram = [UInt8](repeating: 0, count: length)
            emu_read_bytes(core, base, &ram, length)
            var count: Int32 = 0
            let offset = pk_scan_party(ram, length, &count)
            if offset >= 0 {
                let address = base + UInt32(offset)
                scannedParty = address
                return (address, Int(count))
            }
        }
        return nil
    }

    private func publishParty(_ core: OpaquePointer) {
        var members: [PartyMember] = []
        if let location = partyLocation(core) {
            var size = 0
            let rom = emu_rom_data(core, &size)
            var raw = [UInt8](repeating: 0, count: 100)
            for slot in 0..<location.count {
                emu_read_bytes(core, location.address + UInt32(slot * 100), &raw, 100)
                var mon = PKMon()
                guard pk_mon_decode(raw, 100, &mon) else { continue }
                let summary = MonSummary(mon)
                let speciesName = NameLookup.name(rom: rom, size: size, table: speciesTable,
                                                  stride: NameLookup.speciesStride, index: summary.species)
                    ?? "Pokémon n°\(summary.species)"
                let moveNames = summary.moves.map { move in
                    NameLookup.name(rom: rom, size: size, table: moveTable,
                                    stride: NameLookup.moveStride, index: move) ?? "Capacité n°\(move)"
                }
                members.append(PartyMember(id: slot, speciesName: speciesName, summary: summary, moveNames: moveNames,
                                           raw: Data(raw)))
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.party != members else { return }
            self.party = members
        }
    }

    private func healPartyOnThread(_ core: OpaquePointer) -> Int {
        guard let location = partyLocation(core) else { return 0 }
        var healed = 0
        var raw = [UInt8](repeating: 0, count: 100)
        for slot in 0..<location.count {
            let address = location.address + UInt32(slot * 100)
            emu_read_bytes(core, address, &raw, 100)
            guard pk_party_heal(&raw) else { continue }
            // Only the status word (80..83) and current HP (86..87) changed.
            raw.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                emu_write_bytes(core, address + 80, base + 80, 4)
                emu_write_bytes(core, address + 86, base + 86, 2)
            }
            healed += 1
        }
        return healed
    }
}
