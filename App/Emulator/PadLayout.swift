import SwiftUI
import UIKit

/// PERSONNALISER LES BOUTONS: each group of on-screen controls (the pad, the face buttons, START / SELECT, L / R, the DS
/// shortcuts) moved and sized by the player, kept for each skin and each way of holding the phone. The pads lay out as
/// before, then hand each group's views to `apply`, which scales them about the group's middle and moves them.
final class PadLayout: ObservableObject {
    static let shared = PadLayout()
    /// Posted when a place changes: the pads lay out again.
    static let changed = Notification.Name("PadLayoutChanged")

    enum Group: String, CaseIterable, Identifiable {
        case dpad, faces, menu, shoulders, shortcuts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dpad: return "Croix"
            case .faces: return "A B X Y"
            case .menu: return "START / SELECT"
            case .shoulders: return "L / R"
            case .shortcuts: return "Raccourcis DS"
            }
        }
    }

    struct Place: Codable, Equatable {
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var scale: CGFloat = 1
    }

    static let minScale: CGFloat = 0.6
    static let maxScale: CGFloat = 1.6

    /// The editor is open: the pads move groups instead of pressing keys.
    @Published var editing = false {
        didSet { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    @Published var selected: Group = .faces
    /// The pad on screen now (its skin and orientation): what the editor changes.
    @Published private(set) var context = "capsule-portrait"
    @Published private(set) var places: [String: Place] = [:]

    private static let storageKey = "padLayout.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: Place].self, from: data) {
            places = saved
        }
    }

    static func context(skin: String, landscape: Bool) -> String {
        "\(skin)-\(landscape ? "landscape" : "portrait")"
    }

    /// A pad laid out: it's the one the editor works on.
    func show(skin: String, landscape: Bool) {
        let c = Self.context(skin: skin, landscape: landscape)
        if c != context {
            DispatchQueue.main.async { self.context = c }
        }
    }

    func place(_ group: Group, in context: String) -> Place {
        places["\(context)-\(group.rawValue)"] ?? Place()
    }

    func set(_ place: Place, for group: Group, in context: String? = nil) {
        var p = place
        p.scale = min(max(p.scale, Self.minScale), Self.maxScale)
        places["\(context ?? self.context)-\(group.rawValue)"] = p
        save()
    }

    /// The selected group's size, for the editor's slider.
    var selectedScale: CGFloat {
        get { place(selected, in: context).scale }
        set {
            var p = place(selected, in: context)
            p.scale = newValue
            set(p, for: selected)
        }
    }

    /// Everything back where the skin puts it, for the pad on screen.
    func reset() {
        places = places.filter { !$0.key.hasPrefix(context + "-") }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// [views] (one group, laid out with no transform) sized about their common middle and moved, kept inside [bounds].
    func apply(_ views: [UIView], _ group: Group, skin: String, landscape: Bool, in bounds: CGRect) {
        let shown = views.filter { !$0.isHidden }
        guard !shown.isEmpty else { return }
        let p = place(group, in: Self.context(skin: skin, landscape: landscape))
        guard p != Place() else { return }
        let box = shown.map(\.frame).reduce(shown[0].frame) { $0.union($1) }
        let middle = CGPoint(x: box.midX, y: box.midY)
        // The moved group stays on the pad's own area (a finger can always reach it back).
        let half = CGSize(width: box.width * p.scale / 2, height: box.height * p.scale / 2)
        let target = CGPoint(x: min(max(middle.x + p.dx, bounds.minX + half.width), bounds.maxX - half.width),
                             y: min(max(middle.y + p.dy, bounds.minY + half.height), bounds.maxY - half.height))
        for view in views {
            let c = view.center
            view.transform = CGAffineTransform(scaleX: p.scale, y: p.scale)
            view.center = CGPoint(x: target.x + (c.x - middle.x) * p.scale, y: target.y + (c.y - middle.y) * p.scale)
        }
    }

    // MARK: - Dragging (the pads call these while `editing`)

    private var dragStart: CGPoint?
    private var dragFrom = Place()

    func begin(_ group: Group, at point: CGPoint) {
        selected = group
        dragStart = point
        dragFrom = place(group, in: context)
    }

    func drag(to point: CGPoint) {
        guard let start = dragStart else { return }
        var p = dragFrom
        p.dx += point.x - start.x
        p.dy += point.y - start.y
        set(p, for: selected)
    }

    func end() { dragStart = nil }
}

/// The editor's panel, over the game while the player moves the controls.
struct PadLayoutEditor: View {
    @ObservedObject var layout = PadLayout.shared
    let isDS: Bool

    var body: some View {
        VStack(spacing: 10) {
            Text("Glisse un groupe de boutons pour le déplacer")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("Groupe", selection: $layout.selected) {
                ForEach(PadLayout.Group.allCases.filter { isDS || $0 != .shortcuts }) { group in
                    Text(group.title).tag(group)
                }
            }
            .pickerStyle(.menu)
            HStack {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: Binding(get: { layout.selectedScale }, set: { layout.selectedScale = $0 }),
                       in: PadLayout.minScale...PadLayout.maxScale)
                Image(systemName: "plus.magnifyingglass")
            }
            HStack {
                Button("Réinitialiser", role: .destructive) { layout.reset() }
                Spacer()
                Button("Terminé") { layout.editing = false }
                    .bold()
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: 360)
        .padding(.horizontal, 16)
    }
}
