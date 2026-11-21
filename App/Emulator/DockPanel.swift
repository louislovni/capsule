import SwiftUI
import UIKit

/// PokeDaisy's menus (ÉQUIPE, DEX, CARTE, SAC, GUIDE, réglages) in a panel over the controls, the game running on above
/// it: drawn by the core into a canvas of their own (lr_dock), touched as on the 3DS's bottom screen. Its handle opens and
/// closes it; a swipe down on the handle closes it too.
struct DockPanel: View {
    @ObservedObject var session: EmulatorSession
    /// The panel's room (the controls' card), in points.
    let size: CGSize

    @State private var drag: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            handle
            DockCanvasView(session: session)
                .aspectRatio(canvasAspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 12, y: -2)
        .offset(y: max(drag, 0))
        .onAppear { session.setDockSize(canvasRoom) }
        .onChange(of: size) { _ in session.setDockSize(canvasRoom) }
    }

    /// The canvas's room: the panel less its handle.
    private var canvasRoom: CGSize {
        CGSize(width: size.width, height: max(size.height - Self.handleHeight, 1))
    }

    private var canvasAspect: CGFloat {
        let canvas = EmulatorSession.dockCanvas(for: canvasRoom)
        return CGFloat(canvas.width) / CGFloat(canvas.height)
    }

    static let handleHeight: CGFloat = 26

    private var handle: some View {
        Capsule()
            .fill(Color.white.opacity(0.55))
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: Self.handleHeight)
            .contentShape(Rectangle())
            .onTapGesture { close() }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { drag = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height > 60 || value.predictedEndTranslation.height > 160 {
                            close()
                        }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = 0 }
                    }
            )
            .accessibilityLabel("Fermer les menus")
            .accessibilityAddTraits(.isButton)
    }

    private func close() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            session.setDock(open: false)
        }
    }
}

/// The button that opens the panel: a tab on the controls' top edge, as on Android.
struct DockHandleButton: View {
    @ObservedObject var session: EmulatorSession

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                session.setDock(open: true)
            }
        } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 22)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(SquishStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 6).onEnded { value in
                if value.translation.height < -20 {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        session.setDock(open: true)
                    }
                }
            }
        )
        .accessibilityLabel("Menus PokeDaisy")
    }
}

/// The canvas: the core's pixels, sharp, and the finger on them.
struct DockCanvasView: UIViewRepresentable {
    let session: EmulatorSession

    func makeUIView(context: Context) -> DockCanvasUIView {
        let view = DockCanvasUIView()
        session.dockLayer = view.layer
        view.onTouch = { [weak session] point, down in
            session?.dockTouch(point, down: down)
        }
        return view
    }

    func updateUIView(_ uiView: DockCanvasUIView, context: Context) {
        session.dockLayer = uiView.layer
    }
}

final class DockCanvasUIView: UIView {
    var onTouch: ((CGPoint, Bool) -> Void)?
    private var tracking: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.magnificationFilter = .nearest
        layer.contentsGravity = .resize
        backgroundColor = .black
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func unit(_ touch: UITouch) -> CGPoint {
        let p = touch.location(in: self)
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: min(max(p.x / bounds.width, 0), 0.9999), y: min(max(p.y / bounds.height, 0), 0.9999))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracking == nil, let touch = touches.first else { return }
        tracking = touch
        onTouch?(unit(touch), true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracking, touches.contains(touch) else { return }
        onTouch?(unit(touch), true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracking, touches.contains(touch) else { return }
        onTouch?(unit(touch), false)
        tracking = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}
