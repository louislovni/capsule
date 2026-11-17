import Combine
import GameController
import SwiftUI

/// A Bluetooth controller (PlayStation, Xbox, Switch Pro, MFi): its buttons become the
/// game's, alongside the on-screen ones, which step aside while it is connected.
final class GamepadInput: ObservableObject {
    static let shared = GamepadInput()

    /// Name of the connected controller, nil when there is none.
    @Published private(set) var controllerName: String?

    /// Which button is A. By place (default): A is the right-hand button and B the bottom one,
    /// as on a Nintendo console. By label: A is the bottom one (Xbox A, PlayStation ✕).
    @Published var aButtonBottom = UserDefaults.standard.bool(forKey: "gamepadAButtonBottom") {
        didSet { UserDefaults.standard.set(aButtonBottom, forKey: "gamepadAButtonBottom") }
    }

    /// The game's buttons, every time they change.
    var onKeys: ((UInt32) -> Void)?
    /// Right stick pressed in: next speed.
    var onSpeed: (() -> Void)?

    private var controller: GCController?
    private var lastKeys: UInt32 = 0
    private var speedWasDown = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if self?.controller == nil, let controller = note.object as? GCController {
                self?.attach(controller)
            }
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self = self, (note.object as? GCController) === self.controller else { return }
            self.attach(GCController.controllers().first { $0 !== self.controller && $0.extendedGamepad != nil })
        }
        attach(GCController.controllers().first { $0.extendedGamepad != nil })
    }

    private func attach(_ newController: GCController?) {
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = newController
        guard let newController = newController, let pad = newController.extendedGamepad else {
            controllerName = nil
            send(0)
            return
        }
        newController.handlerQueue = .main
        controllerName = newController.vendorName ?? "Manette"
        pad.valueChangedHandler = { [weak self] pad, _ in
            self?.update(pad)
        }
        update(pad)
    }

    private func update(_ pad: GCExtendedGamepad) {
        var keys: UInt32 = 0
        let stick = pad.leftThumbstick
        if pad.dpad.up.isPressed || stick.yAxis.value > 0.5 { keys |= PadKey.up }
        if pad.dpad.down.isPressed || stick.yAxis.value < -0.5 { keys |= PadKey.down }
        if pad.dpad.left.isPressed || stick.xAxis.value < -0.5 { keys |= PadKey.left }
        if pad.dpad.right.isPressed || stick.xAxis.value > 0.5 { keys |= PadKey.right }

        // GameController names the face buttons by place: A bottom, B right, X left, Y top.
        let bottom = pad.buttonA.isPressed, right = pad.buttonB.isPressed
        let left = pad.buttonX.isPressed, top = pad.buttonY.isPressed
        if aButtonBottom {
            if bottom { keys |= PadKey.a }
            if right { keys |= PadKey.b }
            if top { keys |= PadKey.x }
            if left { keys |= PadKey.y }
        } else {
            if right { keys |= PadKey.a }
            if bottom { keys |= PadKey.b }
            if top { keys |= PadKey.x }
            if left { keys |= PadKey.y }
        }
        if pad.leftShoulder.isPressed { keys |= PadKey.l }
        if pad.rightShoulder.isPressed { keys |= PadKey.r }
        if pad.leftTrigger.isPressed { keys |= PadKey.l2 }
        if pad.rightTrigger.isPressed { keys |= PadKey.r2 }
        if pad.buttonMenu.isPressed { keys |= PadKey.start }
        if pad.buttonOptions?.isPressed == true { keys |= PadKey.select }

        let speedDown = pad.rightThumbstickButton?.isPressed == true
        if speedDown && !speedWasDown {
            onSpeed?()
        }
        speedWasDown = speedDown
        send(keys)
    }

    private func send(_ keys: UInt32) {
        guard keys != lastKeys else { return }
        lastKeys = keys
        onKeys?(keys)
    }
}

/// Settings and help for controllers.
struct GamepadSettingsView: View {
    @ObservedObject private var gamepad = GamepadInput.shared

    var body: some View {
        Form {
            Section {
                if let name = gamepad.controllerName {
                    Label("\(name) connectée", systemImage: "gamecontroller.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Aucune manette connectée", systemImage: "gamecontroller")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Pour en connecter une : Réglages de l'iPhone > Bluetooth, puis mets la manette en appairage (PS4/PS5 : PS + Share ; Xbox : bouton d'appairage ; Switch Pro : bouton sur la tranche).")
            }

            Section {
                Picker("Bouton A", selection: $gamepad.aButtonBottom) {
                    Text("À droite, comme sur Nintendo").tag(false)
                    Text("En bas (Xbox A, PlayStation ✕)").tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Bouton A")
            } footer: {
                Text(gamepad.aButtonBottom
                     ? "A en bas, B à droite, X en haut, Y à gauche."
                     : "A à droite, B en bas, X en haut, Y à gauche : les boutons sont à la même place que sur une console Nintendo.")
            }

            Section("Les autres boutons") {
                row("Croix et stick gauche", "Directions")
                row("L1 / R1", "L / R")
                row("L2 / R2", "L2 / R2 de PokeDaisy")
                row("Menu (Options, ≡)", "Start")
                row("Vue (Share, ⧉)", "Select")
                row("Stick droit enfoncé", "Change la vitesse")
            }
        }
        .navigationTitle("Manette")
    }

    private func row(_ button: String, _ action: String) -> some View {
        HStack {
            Text(button)
            Spacer()
            Text(action).foregroundStyle(.secondary)
        }
    }
}
