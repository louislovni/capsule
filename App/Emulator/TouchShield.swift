import SwiftUI
import UIKit

/// SwiftUI's controls laid over the game's UIKit views (the picture, the pad): their frames (window points), so those
/// views leave touches there to the controls. Without it the picture under the sideways toolbar took the touch too:
/// its buttons answered one tap in two, and "…" (a menu) never.
enum TouchShield {
    private(set) static var rects: [String: CGRect] = [:]

    static func set(_ id: String, _ rect: CGRect?) {
        rects[id] = rect
    }

    /// [point] in [view]'s coordinates falls on a shielded control.
    static func covers(_ point: CGPoint, in view: UIView) -> Bool {
        guard !rects.isEmpty, let window = view.window else { return false }
        let inWindow = view.convert(point, to: window)
        return rects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(inWindow) }
    }
}

extension View {
    /// Keeps the game's UIKit views from taking touches over this view (see [TouchShield]).
    func touchShield(_ id: String) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { TouchShield.set(id, geometry.frame(in: .global)) }
                    .onChange(of: geometry.frame(in: .global)) { TouchShield.set(id, $0) }
                    .onDisappear { TouchShield.set(id, nil) }
            }
        )
    }
}
