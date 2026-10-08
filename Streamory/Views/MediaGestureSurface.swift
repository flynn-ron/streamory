import SwiftUI
import UIKit

/// Receives gestures only on media; controls are layered above this surface.
struct MediaGestureSurface: UIViewRepresentable {
    var onSwipe: (ViewerSwipe) -> Void
    var onLongPress: (CGPoint) -> Void
    var onDrag: (CGSize) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.5
        hold.allowableMovement = 18
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        // Moving cancels the hold first; a completed hold cannot also become a swipe.
        pan.require(toFail: hold)
        view.addGestureRecognizer(hold)
        view.addGestureRecognizer(pan)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }
    final class Coordinator: NSObject {
        var parent: MediaGestureSurface
        init(parent: MediaGestureSurface) { self.parent = parent }
        @objc func hold(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began {
                parent.onDrag(.zero)
                parent.onLongPress(recognizer.location(in: recognizer.view))
            }
        }
        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            switch recognizer.state {
            case .changed:
                parent.onDrag(CGSize(width: translation.x, height: translation.y))
            case .ended:
                parent.onDrag(.zero)
                let action = ViewerSwipe.resolve(horizontal: Double(translation.x), vertical: Double(translation.y))
                if action != .none { parent.onSwipe(action) }
            case .cancelled, .failed:
                parent.onDrag(.zero)
            default: break
            }
        }
    }
}

struct TimePortal: Identifiable {
    let id = UUID()
    let record: MediaRecord
    let point: CGPoint?
}

struct TimePortalEffect: View {
    let point: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    var body: some View {
        GeometryReader { geometry in
            let origin = point ?? CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let diameter = hypot(geometry.size.width, geometry.size.height) * 2
            ZStack {
                if !reduceMotion {
                    ForEach(0..<3) { index in
                        Circle().stroke(Color.streamGreen.opacity(0.8 - Double(index) * 0.18), lineWidth: 2)
                            .frame(width: expanded ? diameter * (1 - Double(index) * 0.16) : 18,
                                   height: expanded ? diameter * (1 - Double(index) * 0.16) : 18)
                            .blur(radius: CGFloat(index * 2))
                            .position(origin)
                            .opacity(expanded ? 0 : 1)
                    }
                }
                Circle().fill(RadialGradient(colors: [Color.streamGreen.opacity(0.8), Color.black.opacity(0.95)], center: .center, startRadius: 0, endRadius: diameter / 2))
                    .frame(width: expanded ? diameter : 12, height: expanded ? diameter : 12)
                    .position(origin).opacity(expanded ? 1 : 0)
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 32, weight: .ultraLight))
                    Text("回到过去").font(.title3.weight(.light)).tracking(5)
                }.foregroundStyle(.white).position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .opacity(expanded ? 1 : 0)
            }
            .onAppear { withAnimation(.easeInOut(duration: reduceMotion ? 0.12 : 0.65)) { expanded = true } }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
