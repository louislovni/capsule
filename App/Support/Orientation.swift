import UIKit

/// Lets the game screen turn the phone's interface sideways (and back) on its own,
/// even with the rotation lock on: the "plein écran" button.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientations: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientations
    }
}

enum Orientation {
    /// Forces landscape (true) or gives the phone back its own orientation (false).
    static func force(landscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ??
            UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        AppDelegate.orientations = landscape ? .landscape : .allButUpsideDown
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        let wanted: UIInterfaceOrientationMask = landscape ? .landscape : .portrait
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: wanted)) { _ in }
    }

    /// The panel the GBA core lays its picture out for, in pixels: the whole screen, either way
    /// up (EXPAND then draws the map to every edge, the controller lying over it).
    static func panel(landscape: Bool) -> String {
        let native = UIScreen.main.nativeBounds.size
        let long = Int(max(native.width, native.height))
        let short = Int(min(native.width, native.height))
        return landscape ? "\(long)x\(short)" : "\(short)x\(long)"
    }
}
