import Foundation
import Network

/// Co-op ("Jouer à deux"): PokeDaisy's co-op link, so two players of Pokémon Emerald see each other on the map. The
/// protocol is in C (Core/coop, the same bytes as PokeDaisy's Android app); this class owns what C can't: the TCP
/// listener advertised on the Wi-Fi (Bonjour `_pdcoop._tcp`), the browser that finds the other devices, the
/// connections, and the hand-off of presence updates to and from the game's core.
///
/// Every call into the C host happens on `queue`.
final class CoopService: ObservableObject {
    static let shared = CoopService()

    struct Nearby: Identifiable, Hashable {
        let key: String
        let label: String
        var id: String { key }
    }

    struct Pair: Identifiable, Hashable {
        let index: Int
        let partner: String
        let current: Bool
        var id: Int { index }
    }

    // What the screens show (main thread).
    @Published private(set) var pairStep = Int32(COOP_PAIR_IDLE)
    @Published private(set) var pairFail = Int32(COOP_FAIL_NONE)
    @Published private(set) var partnerName = ""
    @Published private(set) var partnerTrainerId = 0
    @Published private(set) var nearby: [Nearby] = []
    @Published private(set) var pairs: [Pair] = []
    @Published private(set) var linkState = Int32(COOP_LINK_OFF)
    @Published private(set) var linkPartner = ""
    /// The game picked for pairing (or being played) can do co-op.
    @Published private(set) var gameReady = false

    let queue = DispatchQueue(label: "capsule.coop")
    private var host: OpaquePointer?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var advertisedUserData = ""
    private var timer: DispatchSourceTimer?

    private final class Conn {
        let connection: NWConnection
        let outgoing: Bool
        var ready = false
        var ended = false
        init(_ connection: NWConnection, outgoing: Bool) {
            self.connection = connection
            self.outgoing = outgoing
        }
    }
    private var conns: [Int32: Conn] = [:]
    private var nextConn: Int32 = 1
    /// LAN devices: the frontend handle C dials them by (an address of family 0) and their Bonjour endpoint.
    private var lanHandles: [String: Int32] = [:]
    private var lanEndpoints: [Int32: NWEndpoint] = [:]
    private var nextHandle: Int32 = 1

    // Presence for the game being played (the emulation thread takes it).
    private let inboxLock = NSLock()
    private var inbox: [[UInt8]] = []
    private var linkingFlag = false

    /// A monotonic clock in ms, the same for the link and the core's presence.
    static var now: Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    private init() {}

    // MARK: - Starting

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Coop", isDirectory: true)
    }

    /// The device's co-op key: 32 random bytes made once, kept (never sent: only its public half is).
    private static func secretKey() -> [UInt8] {
        let url = directory.appendingPathComponent("secret.key")
        if let data = try? Data(contentsOf: url), data.count == 32 {
            return [UInt8](data)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var key = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &key)
        try? Data(key).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return key
    }

    /// The host, the listener, the browser and the tick: once, on the queue.
    private func startIfNeeded() {
        guard host == nil else { return }
        let secret = Self.secretKey()
        let pairsPath = Self.directory.appendingPathComponent("pairs.txt").path
        let version = "capsule-ios-" + ((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0")
        let me = Unmanaged.passUnretained(self).toOpaque()
        let io = coop_io(
            ctx: me,
            write: { ctx, conn, bytes, n in
                guard let ctx = ctx, let bytes = bytes else { return false }
                return Unmanaged<CoopService>.fromOpaque(ctx).takeUnretainedValue().write(conn, Data(bytes: bytes, count: n))
            },
            close: { ctx, conn in
                guard let ctx = ctx else { return }
                Unmanaged<CoopService>.fromOpaque(ctx).takeUnretainedValue().close(conn)
            },
            dial: { ctx, address in
                guard let ctx = ctx, let address = address else { return -1 }
                return Unmanaged<CoopService>.fromOpaque(ctx).takeUnretainedValue().dial(address.pointee)
            },
            presence: { ctx, bytes, n in
                guard let ctx = ctx, let bytes = bytes else { return }
                Unmanaged<CoopService>.fromOpaque(ctx).takeUnretainedValue().received(Array(UnsafeBufferPointer(start: bytes, count: n)))
            })
        host = secret.withUnsafeBufferPointer { coop_host_new($0.baseAddress, pairsPath, version, io) }
        startListener()
        startBrowser()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.2)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        publish()
    }

    private func cString(_ count: Int, _ body: (UnsafeMutablePointer<CChar>) -> Void) -> String {
        var buffer = [CChar](repeating: 0, count: count)
        buffer.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
        return String(cString: buffer)
    }

    private var lanName: String { cString(18) { coop_host_lan_name(host, $0) } }
    private var peerHex: String { cString(65) { coop_host_peer_hex(host, $0) } }

    private func txtRecord() -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["k"] = peerHex
        if !advertisedUserData.isEmpty {
            txt["u"] = advertisedUserData
        }
        return txt
    }

    private func startListener() {
        guard let listener = try? NWListener(using: .tcp, on: .any) else { return }
        listener.service = NWListener.Service(name: lanName, type: "_pdcoop._tcp", domain: nil, txtRecord: txtRecord())
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.updateAddresses()
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_pdcoop._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.browsed(results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    /// This device's Wi-Fi addresses and the listener's port: they go in its ticket.
    private func updateAddresses() {
        guard let host = host, let port = listener?.port?.rawValue else { return }
        var list: [coop_address] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var cursor = ifaddr
            while let entry = cursor, list.count < 4 {
                let name = String(cString: entry.pointee.ifa_name)
                if (name.hasPrefix("en") || name.hasPrefix("bridge")), let sa = entry.pointee.ifa_addr,
                   sa.pointee.sa_family == UInt8(AF_INET) {
                    var address = coop_address()
                    address.family = 4
                    let s = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                    withUnsafeBytes(of: s) { src in
                        withUnsafeMutableBytes(of: &address.addr) { dst in dst.copyMemory(from: src) }
                    }
                    address.port = port
                    if address.addr.0 != 127 {
                        list.append(address)
                    }
                }
                cursor = entry.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        list.withUnsafeBufferPointer { coop_host_set_addresses(host, $0.baseAddress, Int32($0.count)) }
    }

    // MARK: - Connections (on the queue)

    private func newId() -> Int32 {
        let id = nextConn
        nextConn = nextConn == Int32.max ? 1 : nextConn + 1
        return id
    }

    private func accept(_ connection: NWConnection) {
        let id = newId()
        let conn = Conn(connection, outgoing: false)
        conns[id] = conn
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(id, state)
        }
        connection.start(queue: queue)
    }

    private func dial(_ address: coop_address) -> Int32 {
        let endpoint: NWEndpoint
        if address.family == 0 {
            let handle = Int32(address.addr.0) | Int32(address.addr.1) << 8
            guard let known = lanEndpoints[handle] else { return -1 }
            endpoint = known
        } else {
            let bytes = withUnsafeBytes(of: address.addr) { Data($0) }
            let ip: NWEndpoint.Host
            if address.family == 6, let v6 = IPv6Address(bytes.prefix(16)) {
                ip = .ipv6(v6)
            } else if address.family == 4, let v4 = IPv4Address(bytes.prefix(4)) {
                ip = .ipv4(v4)
            } else {
                return -1
            }
            guard let port = NWEndpoint.Port(rawValue: address.port) else { return -1 }
            endpoint = .hostPort(host: ip, port: port)
        }
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(to: endpoint, using: parameters)
        let id = newId()
        conns[id] = Conn(connection, outgoing: true)
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(id, state)
        }
        connection.start(queue: queue)
        return id
    }

    private func stateChanged(_ id: Int32, _ state: NWConnection.State) {
        guard let host = host, let conn = conns[id], !conn.ended else { return }
        switch state {
        case .ready:
            guard !conn.ready else { return }
            conn.ready = true
            if conn.outgoing {
                coop_host_dialed(host, id, true, Self.now)
            } else {
                coop_host_accepted(host, id, Self.now)
            }
            receive(id)
        case .failed, .cancelled:
            end(id, report: true)
        case .waiting:
            // No route (another network): give up rather than wait.
            if conn.outgoing && !conn.ready {
                end(id, report: true)
            }
        default:
            break
        }
        publish()
    }

    private func receive(_ id: Int32) {
        guard let conn = conns[id] else { return }
        conn.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let host = self.host, let conn = self.conns[id], !conn.ended else { return }
            if let data = data, !data.isEmpty {
                data.withUnsafeBytes { raw in
                    coop_host_data(host, id, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, Self.now)
                }
            }
            if isComplete || error != nil {
                self.end(id, report: true)
            } else if self.conns[id] != nil {
                self.receive(id)
            }
            self.publish()
        }
    }

    /// A connection ended by itself: C hears of it (a dial that failed, or a socket gone).
    private func end(_ id: Int32, report: Bool) {
        guard let conn = conns.removeValue(forKey: id), !conn.ended, let host = host else { return }
        conn.ended = true
        conn.connection.cancel()
        guard report else { return }
        if conn.outgoing && !conn.ready {
            coop_host_dialed(host, id, false, Self.now)
        } else if conn.ready {
            coop_host_gone(host, id, Self.now)
        }
    }

    private func write(_ id: Int32, _ data: Data) -> Bool {
        guard let conn = conns[id], conn.ready, !conn.ended else { return false }
        conn.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.queue.async { self?.end(id, report: true) }
            }
        })
        return true
    }

    /// C closed it: what was queued goes out first.
    private func close(_ id: Int32) {
        guard let conn = conns.removeValue(forKey: id) else { return }
        conn.ended = true
        if conn.ready {
            conn.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                conn.connection.cancel()
            })
        } else {
            conn.connection.cancel()
        }
    }

    private func browsed(_ results: Set<NWBrowser.Result>) {
        guard let host = host else { return }
        let own = peerHex
        var seen = Set<String>()
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let key = txt["k"], key.count == 64, key != own else { continue }
            seen.insert(key)
            let handle: Int32
            if let known = lanHandles[key] {
                handle = known
            } else {
                handle = nextHandle
                nextHandle += 1
                lanHandles[key] = handle
            }
            lanEndpoints[handle] = result.endpoint
            var address = coop_address()
            address.family = 0
            address.addr.0 = UInt8(handle & 0xFF)
            address.addr.1 = UInt8((handle >> 8) & 0xFF)
            coop_host_lan_seen(host, key, txt["u"] ?? "", &address)
        }
        for (key, handle) in lanHandles where !seen.contains(key) {
            coop_host_lan_lost(host, key)
            lanEndpoints[handle] = nil
            lanHandles[key] = nil
        }
        publish()
    }

    private func tick() {
        guard let host = host else { return }
        coop_host_tick(host, Self.now)
        let user = cString(256) { coop_host_lan_user_data(host, $0, 256) }
        if user != advertisedUserData, let listener = listener {
            advertisedUserData = user
            listener.service = NWListener.Service(name: lanName, type: "_pdcoop._tcp", domain: nil, txtRecord: txtRecord())
        }
        let linking = coop_link_state(host) == Int32(COOP_LINK_CONNECTED)
        inboxLock.lock()
        linkingFlag = linking
        inboxLock.unlock()
        publish()
    }

    /// What the screens show, read on the queue and handed to the main thread.
    private func publish() {
        guard let host = host else { return }
        let step = coop_pair_step(host)
        let fail = coop_pair_fail(host)
        var tid: Int32 = 0
        let partner = cString(64) { coop_pair_partner(host, $0, 64, &tid) }
        var near: [Nearby] = []
        let count = coop_pair_nearby_count(host)
        for i in 0..<count {
            var key = [CChar](repeating: 0, count: 65)
            var label = [CChar](repeating: 0, count: 64)
            coop_pair_nearby(host, i, &key, &label, 64)
            near.append(Nearby(key: String(cString: key), label: String(cString: label)))
        }
        var list: [Pair] = []
        for i in 0..<coop_pairs_count(host) {
            var current = false
            let name = cString(64) { coop_pairs_get(host, i, $0, 64, &current) }
            list.append(Pair(index: Int(i), partner: name, current: current))
        }
        let link = coop_link_state(host)
        let linkName = cString(64) { coop_link_partner(host, $0, 64) }
        DispatchQueue.main.async {
            if self.pairStep != step { self.pairStep = step }
            if self.pairFail != fail { self.pairFail = fail }
            if self.partnerName != partner { self.partnerName = partner }
            if self.partnerTrainerId != Int(tid) { self.partnerTrainerId = Int(tid) }
            if self.nearby != near { self.nearby = near }
            if self.pairs != list { self.pairs = list }
            if self.linkState != link { self.linkState = link }
            if self.linkPartner != linkName { self.linkPartner = linkName }
        }
    }

    // MARK: - The game

    /// The ROM's SHA-1 as bytes, nil for a bad string.
    private static func bytes(hex: String) -> [UInt8]? {
        guard hex.count == 40 else { return nil }
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// Picks [game] for co-op (pairing or playing): its ROM's fingerprint and its save. The answer through `gameReady`.
    func use(_ game: Game, then: ((Bool) -> Void)? = nil) {
        Task.detached(priority: .utility) {
            let hex = await RomIdentity.sha1(of: game.romURL)
            let save = try? Data(contentsOf: game.saveURL)
            self.queue.async {
                self.startIfNeeded()
                var ok = false
                if let host = self.host, let hex = hex, let sha = Self.bytes(hex: hex), let save = save {
                    ok = sha.withUnsafeBufferPointer { s in
                        save.withUnsafeBytes { raw in
                            coop_host_set_game(host, s.baseAddress, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
                        }
                    }
                }
                self.publish()
                DispatchQueue.main.async {
                    self.gameReady = ok
                    then?(ok)
                }
            }
        }
    }

    /// Whether [game] could be co-op's (Emerald by its fingerprint), off the main thread.
    static func isCoopGame(_ game: Game) async -> Bool {
        guard game.romURL.pathExtension.lowercased() == "gba", let hex = await RomIdentity.sha1(of: game.romURL),
              let sha = bytes(hex: hex) else { return false }
        return sha.withUnsafeBufferPointer { coop_rom_accepted($0.baseAddress) }
    }

    /// A GBA game starts: if its save has a partner, the link starts with it.
    func gameStarted(_ game: Game) {
        use(game) { [weak self] ok in
            guard ok, let self = self else { return }
            self.queue.async {
                guard let host = self.host, coop_pairs_has_current(host) else { return }
                coop_link_start(host, Self.now)
                self.publish()
            }
        }
    }

    func gameStopped() {
        queue.async {
            guard let host = self.host else { return }
            coop_link_stop(host)
            self.inboxLock.lock()
            self.inbox.removeAll()
            self.linkingFlag = false
            self.inboxLock.unlock()
            self.publish()
        }
    }

    // MARK: - Presence (the emulation thread)

    /// The link is up: the emulation thread runs the core's presence.
    var isLinked: Bool {
        inboxLock.lock()
        defer { inboxLock.unlock() }
        return linkingFlag
    }

    private func received(_ bytes: [UInt8]) {
        inboxLock.lock()
        if inbox.count < 64 {
            inbox.append(bytes)
        }
        inboxLock.unlock()
    }

    func takePresence() -> [[UInt8]] {
        inboxLock.lock()
        defer { inboxLock.unlock() }
        let taken = inbox
        inbox.removeAll()
        return taken
    }

    func sendPresence(_ bytes: [UInt8]) {
        queue.async {
            guard let host = self.host else { return }
            _ = bytes.withUnsafeBufferPointer { coop_link_send_presence(host, $0.baseAddress, $0.count) }
        }
    }

    // MARK: - Pairing (the screen's buttons)

    func openPairing() {
        queue.async {
            guard let host = self.host else { return }
            coop_pair_open(host, Self.now)
            self.updateAddresses()
            self.publish()
        }
    }

    func join(_ player: Nearby) {
        queue.async {
            guard let host = self.host else { return }
            _ = coop_pair_join_lan(host, player.key, Self.now)
            self.publish()
        }
    }

    func accept() {
        queue.async {
            guard let host = self.host else { return }
            coop_pair_accept(host, Self.now)
            self.publish()
        }
    }

    func deny() {
        queue.async {
            guard let host = self.host else { return }
            coop_pair_deny(host, Self.now)
            self.publish()
        }
    }

    func closePairing() {
        queue.async {
            guard let host = self.host else { return }
            coop_pair_close(host)
            self.publish()
        }
    }

    func forget(_ pair: Pair) {
        queue.async {
            guard let host = self.host else { return }
            coop_pairs_remove(host, Int32(pair.index))
            self.publish()
        }
    }
}
