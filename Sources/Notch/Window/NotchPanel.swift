import AppKit
import SwiftUI

/// Geometry of the (real or simulated) notch on the active screen.
enum ScreenMetrics {
    /// The screen that owns the menu bar (its frame origin is (0, 0)).
    static var screen: NSScreen? {
        NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static var hasRealNotch: Bool {
        guard let s = screen else { return false }
        return s.safeAreaInsets.top > 0
    }

    /// Height of the macOS menu bar on the menu-bar screen. Matches the hardware
    /// notch's "safe area" on notched Macs.
    static var menuBarHeight: CGFloat {
        guard let s = screen else { return 24 }
        return max(20, s.frame.maxY - s.visibleFrame.maxY)
    }

    /// Size of the collapsed black "pill". Matches the hardware notch when there is one,
    /// otherwise a simulated pill whose height is exactly the menu bar.
    static var notchSize: CGSize {
        if let s = screen, hasRealNotch {
            let left = s.auxiliaryTopLeftArea?.width ?? 0
            let right = s.auxiliaryTopRightArea?.width ?? 0
            let width = max(180, s.frame.width - left - right)
            return CGSize(width: width, height: s.safeAreaInsets.top)
        }
        return CGSize(width: 220, height: menuBarHeight)
    }

    /// Size of the expanded panel. The window is *always* this size (top-centre,
    /// transparent around the blob when collapsed) so the open/close grow can be a
    /// pure, smooth SwiftUI animation with no window-resize jank.
    static let expandedSize = CGSize(width: 300, height: 108)

    /// Taller music-tab state: transport stays put and the "Saved in" playlist
    /// panel unfolds beneath it. The window is always THIS size — the biggest
    /// blob must fit inside it.
    static let expandedMusicSize = CGSize(width: 300, height: 256)

    /// Compact size used for the transient "screenshot copied" banner.
    static let toastSize = CGSize(width: 252, height: 46)

    // MARK: Side docks
    //
    // Docked to a vertical edge only the collapsed pill differs: it stands
    // upright along the edge. Open, it's the same landscape card as the top
    // dock — same size, same layout — grown out sideways from the edge instead
    // of down from the top.

    /// Collapsed pill on a vertical edge: the top pill's contents (14 pt art,
    /// the small meter, the Claude spinner) at the top pill's sizes, with the
    /// run of black between them cut to about half. 36 pt thick gives the
    /// 14 pt art the same breathing room the 37 pt top pill gives it.
    static let sidePillSize = CGSize(width: 36, height: 150)

    static func collapsedSize(for dock: NotchDock) -> CGSize {
        dock == .top ? notchSize : sidePillSize
    }
    /// Black above and below the tab content. At the top the card's upper edge
    /// merges into the bezel so a tight 10 pt reads fine; on a side dock both
    /// edges are visible rounded corners and the art wants more room.
    static func contentVerticalInset(for dock: NotchDock) -> CGFloat { dock == .top ? 10 : 18 }
    private static func sideExtra(for dock: NotchDock) -> CGFloat {
        2 * (contentVerticalInset(for: dock) - contentVerticalInset(for: .top))
    }
    /// Same card as the top dock, taller by the extra vertical inset on the sides.
    static func expandedSize(for dock: NotchDock) -> CGSize {
        CGSize(width: expandedSize.width, height: expandedSize.height + sideExtra(for: dock))
    }
    /// The fixed window size for a dock — the largest blob it can show.
    static func windowSize(for dock: NotchDock) -> CGSize {
        CGSize(width: expandedMusicSize.width, height: expandedMusicSize.height + sideExtra(for: dock))
    }

    /// The free-floating droplet the notch becomes while it's being dragged
    /// between edges: a small black capsule, sized so it clearly reads as the
    /// notch picked up rather than a stray window.
    static let dropletSize = CGSize(width: 110, height: 34)

    // MARK: Screen-space layout
    //
    // NotchRootView lays the blob out in *screen* coordinates (origin at the
    // screen's top-left, y down); the panel window is only a viewport onto it.
    // That's what lets a drag be one continuous object: the same view keeps
    // drawing the blob as it shrinks into a droplet, rides the cursor and
    // settles onto the new edge, and swapping the viewport back to the small
    // docked frame afterwards doesn't touch the SwiftUI layout at all.

    /// Where a blob of `size` sits for `dock`, in screen-space layout
    /// coordinates: hanging from the top centre, or from the side edge with
    /// its top at the collapsed pill's top (which leaves the pill centred).
    static func blobRect(for dock: NotchDock, size: CGSize) -> CGRect {
        guard let s = screen else { return CGRect(origin: .zero, size: size) }
        let w = s.frame.width, h = s.frame.height
        switch dock {
        case .top:
            return CGRect(x: ((w - size.width) / 2).rounded(), y: 0, width: size.width, height: size.height)
        case .left:
            return CGRect(x: 0, y: ((h - sidePillSize.height) / 2).rounded(),
                          width: size.width, height: size.height)
        case .right:
            return CGRect(x: w - size.width, y: ((h - sidePillSize.height) / 2).rounded(),
                          width: size.width, height: size.height)
        }
    }

    /// `blobRect` in AppKit screen coordinates (for hit-testing the cursor).
    static func blobScreenRect(for dock: NotchDock, size: CGSize) -> NSRect {
        guard let s = screen else { return .zero }
        let r = blobRect(for: dock, size: size)
        return NSRect(x: s.frame.minX + r.minX, y: s.frame.maxY - r.maxY,
                      width: r.width, height: r.height)
    }

    /// Frame of the fixed-size docked window: flush against the docked edge,
    /// its top at the blob's top so fold-outs only ever grow downward.
    static func windowFrame(for dock: NotchDock) -> NSRect {
        guard let s = screen else { return .zero }
        let sf = s.frame
        let size = windowSize(for: dock)
        switch dock {
        case .top:
            return NSRect(x: (sf.minX + sf.maxX) / 2 - size.width / 2,
                          y: sf.maxY - size.height,
                          width: size.width, height: size.height)
        case .left, .right:
            let top = blobScreenRect(for: dock, size: sidePillSize).maxY
            let x = dock == .left ? sf.minX : sf.maxX - size.width
            return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        }
    }
}

/// The classic macOS notch silhouette: flat against its screen edge with little
/// reverse curves where it meets the edge and rounded corners on the free side.
/// `edge` picks which screen edge the flat side presses against; the silhouette
/// is drawn top-docked and axis-swapped into place for the vertical edges.
///
/// `topRadius` rounds the corners on the docked edge instead. With
/// `cornerInset` 0 and both radii at half the height the shape is a capsule —
/// the free-floating droplet — and every parameter animates, so the same shape
/// morphs from notch to droplet and back. A capsule is symmetric, so `edge`
/// can be switched underneath it without a visible change.
struct NotchShape: Shape {
    var cornerInset: CGFloat = 8     // the small reverse curve where it meets the screen edge
    var topRadius: CGFloat = 0
    var bottomRadius: CGFloat = 12
    var edge: Edge = .top

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(cornerInset, AnimatablePair(topRadius, bottomRadius)) }
        set {
            cornerInset = newValue.first
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        switch edge {
        case .top, .bottom:
            return flatTopPath(in: rect)
        case .leading:
            // Transpose (x, y) -> (y, x): the flat top edge lands on the left
            // edge. The silhouette is symmetric, so the mirroring a transpose
            // implies is invisible.
            let base = flatTopPath(in: CGRect(x: 0, y: 0, width: rect.height, height: rect.width))
            return base.applying(CGAffineTransform(a: 0, b: 1, c: 1, d: 0,
                                                   tx: rect.minX, ty: rect.minY))
        case .trailing:
            // (x, y) -> (W - y, x): the flat edge lands on the right.
            let base = flatTopPath(in: CGRect(x: 0, y: 0, width: rect.height, height: rect.width))
            return base.applying(CGAffineTransform(a: 0, b: 1, c: -1, d: 0,
                                                   tx: rect.minX + rect.width, ty: rect.minY))
        }
    }

    private func flatTopPath(in rect: CGRect) -> Path {
        let r = max(0, min(bottomRadius, rect.height / 2))
        let c = max(0, min(cornerInset, rect.width / 2))
        let t = max(0, min(topRadius, rect.height / 2, rect.width / 2))
        // The top corners are one quad curve each, whose endpoints slide with
        // the parameters: at t = 0 it's the concave flare out to the screen
        // edge, at c = 0 it's a convex rounded corner, and in between it
        // interpolates smoothly.
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + c, y: rect.minY + c + t),
                       control: CGPoint(x: rect.minX + c, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + c + r, y: rect.maxY),
                       control: CGPoint(x: rect.minX + c, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - c - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - c, y: rect.maxY - r),
                       control: CGPoint(x: rect.maxX - c, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - c, y: rect.minY + c + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.minY),
                       control: CGPoint(x: rect.maxX - c, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Borderless floating panel hugging one screen edge. The hosting view inside
/// always covers the whole screen and lays the blob out in screen coordinates;
/// the window is a viewport onto it — the small docked frame normally, the
/// whole screen while the blob is being dragged between edges (`setViewport`).
/// Mouse events are ignored while collapsed so the menu bar underneath stays usable.
final class NotchPanel: NSPanel {
    private let hosting: SwipeHostingView<AnyView>
    /// Clear container the screen-sized hosting view is offset inside. (A
    /// window's contentView can't be offset, so it isn't the host itself.)
    private let container = NSView()

    /// Which screen edge the window hugs. AppDelegate mirrors `NotchState.dock`
    /// into this; `reposition()` reads it so every re-show lands on the right edge.
    var dock: NotchDock = .top

    /// Callback fired on a horizontal two-finger swipe over the panel. `dir` is +1
    /// for swipe-left (→ next tab) and -1 for swipe-right (→ previous tab), matching
    /// natural-scrolling direction.
    var onHorizontalSwipe: ((Int) -> Void)? {
        get { hosting.onHorizontalSwipe }
        set { hosting.onHorizontalSwipe = newValue }
    }
    /// See `SwipeHostingView.onMouseActivity`.
    var onMouseActivity: (() -> Void)? {
        get { hosting.onMouseActivity }
        set { hosting.onMouseActivity = newValue }
    }

    init(rootView: some View) {
        let host = SwipeHostingView(rootView: AnyView(rootView))
        host.autoresizingMask = []
        // The window's size is ours (`setViewport`), never the content's: with
        // the default sizing options a blob laid out wider than the window grew
        // the window past the screen edge, and windows never shrink back — the
        // notch was left drawn off-screen for good.
        host.sizingOptions = []
        self.hosting = host
        container.addSubview(host)

        super.init(contentRect: NSRect(origin: .zero, size: ScreenMetrics.expandedMusicSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        // Just below the cursor window level. Tested 2026-07-22: window level has
        // no bearing on the Spaces-transition blank-out (the menu-bar band at 25
        // occludes identically), so this is purely about drawing over the menu
        // bar and over full-screen apps.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        // We intentionally don't use `.fullScreenAuxiliary`. WindowServer occludes
        // auxiliary windows the moment it detects a 3-finger gesture inside a
        // full-screen Space (so its own cross-fade can run unobstructed). Instead,
        // we'll explicitly pin the window to every Space via SpaceAttacher, which
        // bypasses that special-case path.
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if #available(macOS 13.0, *) {
            behavior.insert(.canJoinAllApplications)
        }
        collectionBehavior = behavior
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true   // collapsed at launch

        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Don't let AppKit shove the window down to keep it below the menu bar —
    /// the notch lives *at* the screen edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Move the docked viewport to its edge.
    func reposition() {
        let f = ScreenMetrics.windowFrame(for: dock)
        guard f.width > 0 else { return }
        setViewport(f)
    }

    /// Cover the whole screen — used for the duration of a drag so the blob
    /// can travel anywhere.
    func setFullScreenViewport() {
        guard let s = ScreenMetrics.screen else { return }
        setViewport(s.frame)
    }

    /// Show `frame` (screen coordinates) of the screen-sized content. The
    /// hosting view is offset inside the window so it stays put on screen; the
    /// SwiftUI layout never changes, only how much of it the window shows,
    /// which is what keeps a viewport swap pixel-identical.
    private func setViewport(_ frame: NSRect) {
        guard let s = ScreenMetrics.screen else { return }
        hosting.frame = NSRect(x: s.frame.minX - frame.minX, y: s.frame.minY - frame.minY,
                               width: s.frame.width, height: s.frame.height)
        setFrame(frame, display: true)
    }

    func show() {
        reposition()
        orderFrontRegardless()
        // Pin to every existing Space — including full-screen ones, which the
        // removed `.fullScreenAuxiliary` would have handled (poorly).
        SpaceAttacher.attachToAllSpaces(self)
    }
}

/// NSHostingView that watches for two-finger horizontal swipes and reports them.
/// Scroll events over an inner NSScrollView (e.g. the Screenshots strip) are consumed
/// there first and never reach us, so swipe-to-switch only fires on tabs with no
/// horizontal scroller.
final class SwipeHostingView<Root: View>: NSHostingView<Root> {
    var onHorizontalSwipe: ((Int) -> Void)?
    /// Fired on every mouse-move / enter / exit over the panel. AppDelegate
    /// points this at its hover evaluation.
    var onMouseActivity: (() -> Void)?

    /// Our own tracking area for mouse-moved events over the visible window.
    /// SwiftUI used to install one for its `.onHover` modifiers, and the whole
    /// hover pipeline (the AppDelegate local monitor included) fed on the
    /// events it generated; with the panel's hover now computed from the
    /// tracked cursor there are no `.onHover`s left, so the events are ours
    /// to generate.
    private var moveArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = moveArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        moveArea = a
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseActivity?()
        super.mouseMoved(with: event)
    }
    override func mouseEntered(with event: NSEvent) {
        onMouseActivity?()
        super.mouseEntered(with: event)
    }
    override func mouseExited(with event: NSEvent) {
        onMouseActivity?()
        super.mouseExited(with: event)
    }

    private var firedThisGesture = false
    private var lastEventTime: TimeInterval = 0

    /// Deliver the first click after switching apps directly to the SwiftUI
    /// hit-target instead of letting AppKit eat it as the "activate / make-key"
    /// click. Without this, the gear icon (and any other tap target) needs a
    /// throwaway first click whenever focus is elsewhere.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        // A new swipe is either a fresh `.began` phase (trackpad) or a clear pause
        // since the last event (mouse-wheel / momentum that already settled).
        if event.phase.contains(.began) || now - lastEventTime > 0.35 {
            firedThisGesture = false
        }
        lastEventTime = now

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if !firedThisGesture,
           abs(dx) > 5,
           abs(dx) > abs(dy) * 1.3 {
            // Natural scrolling: a left swipe yields negative dx — that should move you
            // to the *next* tab (so swipe-left = music → screenshots).
            let dir = dx < 0 ? 1 : -1
            onHorizontalSwipe?(dir)
            firedThisGesture = true
        }
        super.scrollWheel(with: event)
    }
}
