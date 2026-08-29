import AppKit
import SwiftUI

/// Drives drag-to-move: while the user holds the blob, the whole panel chases the
/// cursor with a springy lag and the blob condenses into a droplet; on release it
/// snaps to the nearest of the three docks (top / left / right), overshooting into
/// the edge a touch before settling, and the choice is persisted.
///
/// The controller never reads gesture coordinates. SwiftUI's drag gesture only
/// marks the press's lifetime (begin on first movement, end on release); position
/// comes from `NSEvent.mouseLocation` and button state from
/// `NSEvent.pressedMouseButtons` on a 120 Hz tick, so the window moving out from
/// under the gesture — or the mid-drag view-tree swap to the droplet — can't
/// strand the drag.
@MainActor
final class NotchDragController {
    private weak var panel: NotchPanel?
    private let notch: NotchState

    private var tick: Timer?
    /// Frame-origin velocity in points/second, shared by the chase and the settle
    /// spring so the landing inherits the throw's momentum.
    private var velocity = CGVector.zero
    /// Set on release: the frame origin of the chosen dock. Nil while chasing.
    private var settleTo: CGPoint?

    init(panel: NotchPanel, notch: NotchState) {
        self.panel = panel
        self.notch = notch
    }

    /// The press has moved far enough to count as a drag: tear the blob off.
    func begin() {
        guard !notch.isDockDragging, settleTo == nil else { return }
        notch.cancelScheduledClose()
        notch.isDockDragging = true
        velocity = .zero
        Haptics.tick()
        startTicking()
    }

    /// The press ended: pick the nearest edge and spring the window home.
    func end() {
        guard notch.isDockDragging, settleTo == nil else { return }
        let dock = Self.nearestDock(to: NSEvent.mouseLocation)
        notch.dock = dock
        panel?.dock = dock
        settleTo = ScreenMetrics.windowFrame(for: dock).origin
        notch.close()
        Haptics.tick()
        // The tick keeps running; `isDockDragging` stays true so the droplet
        // rides the settle and only melts into the pill once it has landed.
    }

    private func startTicking() {
        tick?.invalidate()
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func step() {
        guard let panel else { stop(); return }
        let dt: CGFloat = 1.0 / 120.0
        if let home = settleTo {
            // Slightly underdamped spring on the frame origin — the blob squishes
            // into the edge and rebounds, which is what sells the liquid landing.
            let o = panel.frame.origin
            velocity.dx += (170 * (home.x - o.x) - 22 * velocity.dx) * dt
            velocity.dy += (170 * (home.y - o.y) - 22 * velocity.dy) * dt
            let next = CGPoint(x: o.x + velocity.dx * dt, y: o.y + velocity.dy * dt)
            if abs(next.x - home.x) < 0.5, abs(next.y - home.y) < 0.5,
               abs(velocity.dx) < 6, abs(velocity.dy) < 6 {
                panel.setFrameOrigin(home)
                finish()
            } else {
                panel.setFrameOrigin(next)
                publishStretch()
            }
        } else if notch.isDockDragging {
            // A release can slip past the SwiftUI gesture (its view was swapped
            // for the droplet) — the physical button state is the ground truth.
            if NSEvent.pressedMouseButtons & 1 == 0 { end(); return }
            // Exponential chase toward the cursor; the lag is what reads as fluid.
            let f = panel.frame
            let mouse = NSEvent.mouseLocation
            let nx = f.midX + (mouse.x - f.midX) * 0.22
            let ny = f.midY + (mouse.y - f.midY) * 0.22
            velocity = CGVector(dx: (nx - f.midX) / dt, dy: (ny - f.midY) / dt)
            panel.setFrameOrigin(CGPoint(x: nx - f.width / 2, y: ny - f.height / 2))
            publishStretch()
        } else {
            stop()
        }
    }

    /// Squash & stretch from the window's velocity: elongate along the direction
    /// of travel, thin out across it, harder the faster it moves.
    private func publishStretch() {
        let speed = min(1, hypot(velocity.dx, velocity.dy) / 2600)
        let s = 1 + 0.16 * speed
        let alongX = abs(velocity.dx) >= abs(velocity.dy)
        let new = CGSize(width: alongX ? s : 1 / s, height: alongX ? 1 / s : s)
        if abs(new.width - notch.dragStretch.width) > 0.01
            || abs(new.height - notch.dragStretch.height) > 0.01 {
            notch.dragStretch = new
        }
    }

    private func finish() {
        settleTo = nil
        notch.dragStretch = CGSize(width: 1, height: 1)
        notch.isDockDragging = false
        stop()
        // The window changed frame; make sure it's still pinned to every Space.
        if let panel { SpaceAttacher.attachToAllSpaces(panel) }
    }

    private func stop() {
        tick?.invalidate()
        tick = nil
    }

    /// The dock whose screen edge is closest to `point` (bottom isn't a dock).
    static func nearestDock(to point: CGPoint) -> NotchDock {
        guard let s = ScreenMetrics.screen else { return .top }
        let sf = s.frame
        let dTop = sf.maxY - point.y
        let dLeft = point.x - sf.minX
        let dRight = sf.maxX - point.x
        if dTop <= dLeft && dTop <= dRight { return .top }
        return dLeft <= dRight ? .left : .right
    }
}
