import AppKit
import SwiftUI

/// Drives drag-to-move. While the user holds the open blob and moves, the
/// blob hides in place and `DockDragOverlay` takes over: a black droplet rides
/// the cursor and a grey outlined pill marks the nearest edge. On release the
/// droplet springs onto that outline, then the real panel is moved to the new
/// dock and shown, and the choice is persisted.
///
/// The controller never reads gesture coordinates. SwiftUI's drag gesture only
/// marks the start of the press; from then on the cursor comes from
/// `NSEvent.mouseLocation` and the button state from
/// `NSEvent.pressedMouseButtons` on a 120 Hz tick, so hiding the blob (or the
/// panel ignoring mouse events once closed) can't strand the drag.
@MainActor
final class NotchDragController {
    private weak var panel: NotchPanel?
    private let notch: NotchState
    private let overlay = DockDragOverlay()

    private var tick: Timer?
    private var settleWork: DispatchWorkItem?
    /// The screen the drag is happening on — the one the notch lives on.
    private var screen: NSScreen?

    /// How long the droplet takes to land before the panel takes over.
    private static let settleDuration: TimeInterval = 0.42

    init(panel: NotchPanel, notch: NotchState) {
        self.panel = panel
        self.notch = notch
    }

    /// The press has moved far enough to count as a drag: tear the blob off.
    func begin() {
        guard !notch.isDockDragging, let screen = ScreenMetrics.screen else { return }
        self.screen = screen
        notch.cancelScheduledClose()
        notch.close()
        notch.isDockDragging = true
        Haptics.tick()
        notchLog("[notch.dock] drag began from \(notch.dock)")

        let model = overlay.model
        model.target = notch.dock
        model.cursor = Self.overlayPoint(NSEvent.mouseLocation, on: screen)
        model.phase = .dragging
        overlay.present(on: screen)
        startTicking()
    }

    /// The press ended: land on the nearest edge.
    func end() {
        guard notch.isDockDragging, overlay.model.phase == .dragging else { return }
        stopTicking()
        let dock = overlay.model.target
        overlay.model.phase = .settling
        Haptics.tick()
        notchLog("[notch.dock] released → \(dock)")

        let work = DispatchWorkItem { [weak self] in self?.land(on: dock) }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration, execute: work)
    }

    private func land(on dock: NotchDock) {
        settleWork = nil
        notch.dock = dock
        if let panel {
            panel.dock = dock
            panel.reposition()
            panel.orderFrontRegardless()
            SpaceAttacher.attachToAllSpaces(panel)
            notchLog("[notch.dock] landed on \(dock), window \(panel.frame)")
        }
        // The panel's pill fades in on the new edge as the droplet fades out
        // underneath it, so the handoff reads as one object.
        notch.isDockDragging = false
        overlay.model.phase = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.overlay.model.phase == .idle else { return }
            self.overlay.orderOut(nil)
        }
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
        guard let screen, overlay.model.phase == .dragging else { stopTicking(); return }
        // A release can slip past the SwiftUI gesture (the blob it was attached
        // to is hidden and the panel ignores mouse events once closed) — the
        // physical button state is the ground truth.
        if NSEvent.pressedMouseButtons & 1 == 0 { end(); return }
        let mouse = NSEvent.mouseLocation
        let model = overlay.model
        model.cursor = Self.overlayPoint(mouse, on: screen)
        let target = Self.nearestDock(to: mouse, on: screen)
        if target != model.target {
            model.target = target
            Haptics.tick()
        }
    }

    /// Screen point → overlay SwiftUI coordinates (top-left origin, y down).
    private static func overlayPoint(_ p: CGPoint, on screen: NSScreen) -> CGPoint {
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
