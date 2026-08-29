import AppKit
import SwiftUI

/// Drives drag-to-move. While the user holds the open blob and moves, the
/// panel's window widens to cover the screen and the blob itself — the same
/// SwiftUI view, laid out in screen coordinates — shrinks into a black droplet
/// that rides the cursor while grey outlined pills mark every edge it can land
/// on. On release the droplet morphs straight into the pill on the nearest
/// edge; once it has settled the window shrinks back to that edge's docked
/// viewport (a pixel-identical swap) and the choice is persisted. One object
/// the whole way — nothing is hidden, swapped or faded.
///
/// The controller never reads gesture coordinates. SwiftUI's drag gesture only
/// marks the start of the press; from then on the cursor comes from
/// `NSEvent.mouseLocation` and the button state from
/// `NSEvent.pressedMouseButtons` on a 120 Hz tick, so the panel ignoring mouse
/// events once closed can't strand the drag.
@MainActor
final class NotchDragController {
    private weak var panel: NotchPanel?
    private let notch: NotchState

    private var tick: Timer?
    private var settleWork: DispatchWorkItem?
    /// The screen the drag is happening on — the one the notch lives on.
    private var screen: NSScreen?

    /// How long after release the window keeps its full-screen viewport. The
    /// landing spring is critically damped with a 0.34 s response, so by now
    /// the blob is at rest inside the docked frame it's about to be cropped to.
    private static let settleDuration: TimeInterval = 0.7

    init(panel: NotchPanel, notch: NotchState) {
        self.panel = panel
        self.notch = notch
    }

    /// The press has moved far enough to count as a drag: tear the blob off.
    func begin() {
        guard !notch.isDockDragging, !notch.isDockLanding, let screen = ScreenMetrics.screen else { return }
        self.screen = screen
        settleWork?.cancel(); settleWork = nil
        notch.cancelScheduledClose()
        Haptics.tick()
        notchLog("[notch.dock] drag began from \(notch.dock)")

        // Widen the viewport first: the layout underneath doesn't change, so
        // this is invisible, and the blob is then free to leave its edge.
        panel?.setFullScreenViewport()
        notch.dragCursor = Self.layoutPoint(NSEvent.mouseLocation, on: screen)
        notch.dragTarget = notch.dock
        notch.close()
        notch.isDockDragging = true
        startTicking()
    }

    /// The press ended: land on the nearest edge.
    func end() {
        guard notch.isDockDragging else { return }
        stopTicking()
        let dock = notch.dragTarget
        Haptics.tick()
        notchLog("[notch.dock] released → \(dock)")

        // One state change: the droplet's rect and silhouette animate straight
        // into the new edge's pill (NotchRootView keys its landing spring on
        // `isDockDragging`), and the pill's contents morph with it.
        notch.dock = dock
        notch.isDockDragging = false
        notch.isDockLanding = true

        let work = DispatchWorkItem { [weak self] in self?.land(on: dock) }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration, execute: work)
    }

    private func land(on dock: NotchDock) {
        settleWork = nil
        if let panel {
            panel.dock = dock
            panel.reposition()
            panel.orderFrontRegardless()
            SpaceAttacher.attachToAllSpaces(panel)
            notchLog("[notch.dock] landed on \(dock), window \(panel.frame)")
        }
        notch.isDockLanding = false
    }

    // MARK: Tick

    private func startTicking() {
        tick?.invalidate()
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func stopTicking() {
        tick?.invalidate()
        tick = nil
    }

    private func step() {
        guard let screen, notch.isDockDragging else { stopTicking(); return }
        // A release can slip past the SwiftUI gesture (the panel ignores mouse
        // events once closed) — the physical button state is the ground truth.
        if NSEvent.pressedMouseButtons & 1 == 0 { end(); return }
        let mouse = NSEvent.mouseLocation
        notch.dragCursor = Self.layoutPoint(mouse, on: screen)
        let target = Self.nearestDock(to: mouse, on: screen)
        if target != notch.dragTarget {
            notch.dragTarget = target
            Haptics.tick()
        }
    }

    /// AppKit screen point → screen-space layout coordinates (top-left origin, y down).
    private static func layoutPoint(_ p: CGPoint, on screen: NSScreen) -> CGPoint {
        CGPoint(x: p.x - screen.frame.minX, y: screen.frame.maxY - p.y)
    }

    /// The dock whose screen edge is closest to `point`. The bottom isn't a
    /// dock, so near the bottom it's whichever side is closer.
    static func nearestDock(to point: CGPoint, on screen: NSScreen) -> NotchDock {
        let sf = screen.frame
        let dTop = sf.maxY - point.y
        let dLeft = point.x - sf.minX
        let dRight = sf.maxX - point.x
        if dTop <= dLeft && dTop <= dRight { return .top }
        return dLeft <= dRight ? .left : .right
    }
}
