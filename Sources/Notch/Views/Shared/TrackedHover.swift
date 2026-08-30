import SwiftUI
import Combine

/// The cursor's position, published on every mouse move by AppDelegate's
/// monitors and the panel's own tracking area. The value itself is only a
/// change signal — hover hit-testing reads `NSEvent.mouseLocation` directly.
///
/// Exists because SwiftUI's `.onHover` rides on AppKit tracking areas, and
/// with the panel's screen-sized, offset hosting view that machinery proved
/// laggy and unreliable.
@MainActor
final class CursorTracker: ObservableObject {
    @Published var point: CGPoint?
}

/// `.trackedHover { inside in … }` — drop-in replacement for `.onHover` for
/// views living inside the notch panel.
///
/// The measurement is done by an AppKit probe view sitting behind the
/// content, not by GeometryReader: the blob (and the corner controls) are
/// positioned with `.offset`, a pure render transform that SwiftUI geometry
/// ignores — `frame(in: .global)` reports where the view *would* be without
/// it. An embedded NSView is placed at the view's true position, transforms
/// and all, so `convert` + `convertToScreen` give the real on-screen rect to
/// test the real cursor against.
///
/// Crucially the probe does NOT evaluate from `updateNSView`: `perform`
/// mutates SwiftUI state (`hovering` etc.), and a state change made during a
/// view update is dropped ("Modifying state during view update"). Instead the
/// probe subscribes to the tracker itself — cursor changes arrive from the
/// AppDelegate event monitors, outside any render pass — and layout-driven
/// re-checks are deferred to the next runloop tick.
private struct TrackedHover: ViewModifier {
    @EnvironmentObject private var cursor: CursorTracker
    let perform: (Bool) -> Void

    func body(content: Content) -> some View {
        content.background(
            HoverProbe(tracker: cursor, perform: perform)
                .allowsHitTesting(false)
        )
    }
}

private struct HoverProbe: NSViewRepresentable {
    let tracker: CursorTracker
    let perform: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.perform = perform
        v.subscribe(to: tracker)
        return v
    }

    func updateNSView(_ v: ProbeView, context: Context) {
        v.perform = perform
        v.subscribe(to: tracker)
        // A re-render usually means layout changed under a possibly stationary
        // cursor — re-check, but on the next tick, outside this view update.
        v.scheduleEvaluate()
    }
}

private final class ProbeView: NSView {
    var perform: ((Bool) -> Void)?
    private var inside = false
    private var subscription: AnyCancellable?
    private weak var tracker: CursorTracker?
    private var evaluatePending = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func subscribe(to t: CursorTracker) {
        guard tracker !== t else { return }
        tracker = t
        subscription = t.$point
            .dropFirst()   // the replayed current value fires during body evaluation
            .sink { [weak self] _ in self?.evaluate() }
    }

    func scheduleEvaluate() {
        guard !evaluatePending else { return }
        evaluatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.evaluatePending = false
            self.evaluate()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleEvaluate()
    }

    private func evaluate() {
        guard let w = window else { return }
        let screenRect = w.convertToScreen(convert(bounds, to: nil))
        let hit = screenRect.contains(NSEvent.mouseLocation)
        if hit != inside {
            inside = hit
            perform?(hit)
        }
    }
}

extension View {
    func trackedHover(perform: @escaping (Bool) -> Void) -> some View {
        modifier(TrackedHover(perform: perform))
    }
}
