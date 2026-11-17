import Combine
import Foundation
import MultipeerConnectivity
import UIKit

/// What two phones say to each other during a trade.
enum TradeMessage: Codable {
    /// The Pokémon this side puts up (nil: none any more).
    case offer(BankEntry?)
    /// This side agrees to give `mine` for `theirs`. Only counts while both offers are still those.
    case confirm(mine: UUID, theirs: UUID)
    /// This side has made the swap in its bank.
    case done
}

/// A trade with an iPhone nearby (Bluetooth / Wi-Fi, no server): both phones look for each
/// other, one invites, the other accepts; each puts up a Pokémon from its bank, both confirm
/// the same pair, and each bank swaps its own for the other's.
final class TradeSession: NSObject, ObservableObject {
    enum Phase: Equatable {
        case searching
        case connecting(String)
        case connected(String)
        case finished(received: String, given: String)
        case failed(String)
    }

    struct Invitation: Identifiable {
        let id = UUID()
        let name: String
        let answer: (Bool) -> Void
    }

    static let serviceType = "capsule-trade"
    private static let nameKey = "tradeName"

    @Published private(set) var phase: Phase = .searching
    @Published private(set) var nearby: [MCPeerID] = []
    @Published private(set) var myOffer: BankEntry?
    @Published private(set) var theirOffer: BankEntry?
    @Published private(set) var iConfirmed = false
    @Published private(set) var peerConfirm: (mine: UUID, theirs: UUID)?
    @Published var invitation: Invitation?

    /// The name the other phone sees.
    static var displayName: String {
        get {
            let saved = UserDefaults.standard.string(forKey: nameKey) ?? ""
            return saved.isEmpty ? UIDevice.current.name : saved
        }
        set {
            UserDefaults.standard.set(String(newValue.prefix(40)), forKey: nameKey)
        }
    }

    private let bank: BankStore
    private var me: MCPeerID
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser
    private var browser: MCNearbyServiceBrowser
    private var running = false
    private var committed = false

    init(bank: BankStore) {
        self.bank = bank
        let peer = MCPeerID(displayName: Self.displayName)
        me = peer
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)
        super.init()
        wire()
    }

    private func wire() {
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    /// The other side confirmed exactly the pair on the table now.
    var theyConfirmed: Bool {
        guard let confirm = peerConfirm, let mine = myOffer, let theirs = theirOffer else { return false }
        return confirm.mine == theirs.id && confirm.theirs == mine.id
    }

    var peerName: String? {
        session.connectedPeers.first?.displayName
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        committed = false
        nearby = []
        myOffer = nil
        theirOffer = nil
        iConfirmed = false
        peerConfirm = nil
        phase = .searching
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        guard running else { return }
        running = false
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    /// A new name: the phone shows up again under it.
    func rename(_ name: String) {
        Self.displayName = name
        stop()
        let peer = MCPeerID(displayName: Self.displayName)
        me = peer
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)
        wire()
        start()
    }

    /// Back to looking for phones, after a trade or a lost link.
    func restart() {
        stop()
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        start()
    }

    func invite(_ peer: MCPeerID) {
        phase = .connecting(peer.displayName)
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 30)
    }

    // MARK: - The trade

    func offer(_ entry: BankEntry?) {
        myOffer = entry
        iConfirmed = false
        peerConfirm = nil
        send(.offer(entry))
    }

    func confirm() {
        guard let mine = myOffer, let theirs = theirOffer, !committed else { return }
        iConfirmed = true
        send(.confirm(mine: mine.id, theirs: theirs.id))
        commitIfReady()
    }

    private func commitIfReady() {
        guard !committed, iConfirmed, theyConfirmed, let mine = myOffer, let theirs = theirOffer else { return }
        committed = true
        do {
            let received = try bank.trade(giving: mine, receiving: theirs)
            phase = .finished(received: received.displayName, given: mine.displayName)
            send(.done)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func send(_ message: TradeMessage) {
        guard !session.connectedPeers.isEmpty, let data = try? Self.encoder.encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func receive(_ message: TradeMessage) {
        switch message {
        case .offer(let entry):
            guard !committed else { return }
            theirOffer = entry
            // A new offer on either side undoes both agreements.
            iConfirmed = false
            peerConfirm = nil
        case .confirm(let mine, let theirs):
            peerConfirm = (mine, theirs)
            commitIfReady()
        case .done:
            break
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - MultipeerConnectivity (their callbacks come on background queues)

extension TradeSession: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            guard session === self.session else { return }
            switch state {
            case .connected:
                self.advertiser.stopAdvertisingPeer()
                self.browser.stopBrowsingForPeers()
                self.phase = .connected(peerID.displayName)
                // Whatever was put up before the link: sent again now that it's there.
                if let mine = self.myOffer {
                    self.send(.offer(mine))
                }
            case .connecting:
                self.phase = .connecting(peerID.displayName)
            case .notConnected:
                if case .finished = self.phase { return }
                if case .failed = self.phase { return }
                guard self.running else { return }
                if case .connecting = self.phase {
                    self.phase = .failed("\(peerID.displayName) n'a pas accepté, ou ne répond pas.")
                } else {
                    self.phase = .failed("La connexion avec \(peerID.displayName) a été perdue. Rien n'a été échangé.")
                }
            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? Self.decoder.decode(TradeMessage.self, from: data) else { return }
        DispatchQueue.main.async {
            guard session === self.session else { return }
            self.receive(message)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {}

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {}
}

extension TradeSession: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            guard self.session.connectedPeers.isEmpty else {
                invitationHandler(false, nil)
                return
            }
            let session = self.session
            self.invitation = Invitation(name: peerID.displayName) { accepted in
                invitationHandler(accepted, accepted ? session : nil)
            }
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async {
            self.phase = .failed("Impossible de se rendre visible : \(error.localizedDescription). Vérifie que Capsule a accès au réseau local (Réglages > Confidentialité > Réseau local).")
        }
    }
}

extension TradeSession: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard browser === self.browser, peerID != self.me, !self.nearby.contains(peerID) else { return }
            self.nearby.append(peerID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.nearby.removeAll { $0 == peerID }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async {
            self.phase = .failed("Impossible de chercher les iPhones proches : \(error.localizedDescription). Vérifie que Capsule a accès au réseau local (Réglages > Confidentialité > Réseau local).")
        }
    }
}
