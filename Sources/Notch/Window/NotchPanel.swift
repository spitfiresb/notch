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

    /// Frame of the fixed-size window for a dock: flush against the docked edge.
    /// The blob is anchored to the window's top on every dock, so opening only
    /// ever grows downward and the content above never shifts. On the sides the
    /// window's top sits at the collapsed pill's top, which leaves the pill
    /// centred on the edge.
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
            let top = sf.midY + sidePillSize.height / 2
            let x = dock == .left ? sf.minX : sf.maxX - size.width
            return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        }
    }
}

/// The classic macOS notch silhouette: flat against its screen edge with little
/// reverse curves where it meets the edge and rounded corners on the free side.
/// `edge` picks which screen edge the flat side presses against; the silhouette
/// is drawn top-docked and axis-swapped into place for the vertical edges.
struct NotchShape: Shape {
    var cornerInset: CGFloat = 8     // the small reverse curve where it meets the screen edge
    var bottomRadius: CGFloat = 12
    var edge: Edge = .top

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
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
        let r = min(bottomRadius, rect.height / 2)
        let c = min(cornerInset, rect.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + c, y: rect.minY + c),
                       control: CGPoint(x: rect.minX + c, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + c + r, y: rect.maxY),
                       control: CGPoint(x: rect.minX + c, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - c - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - c, y: rect.maxY - r),
                       control: CGPoint(x: rect.maxX - c, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - c, y: rect.minY + c))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - c, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Borderless floating panel pinned to the top centre of the screen. Fixed size
/// (`ScreenMetrics.expandedSize`); the blob inside grows/shrinks with SwiftUI.
/// Mouse events are ignored while collapsed so the menu bar underneath stays usable.
final class NotchPanel: NSPanel {
    private let hosting: SwipeHostingView<AnyView>

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

    init(rootView: some View) {
        let host = SwipeHostingView(rootView: AnyView(rootView))
        host.autoresizingMask = [.width, .height]
        // The window's size is ours (`reposition`), never the content's: with the
        // default sizing options a blob laid out wider than the window grew the
        // window past the screen edge, and windows never shrink back — the notch
        // was left drawn off-screen for good.
        host.sizingOptions = []
        self.hosting = host

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

        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Don't let AppKit shove the window down to keep it below the menu bar —
    /// the notch lives *at* the screen edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func reposition() {
        let f = ScreenMetrics.windowFrame(for: dock)
        guard f.width > 0 else { return }
        setFrame(f, display: true)
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
