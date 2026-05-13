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

    /// Size of the collapsed black "pill". Matches the hardware notch when there is one,
    /// otherwise a sensible simulated size sitting over the middle of the menu bar.
    static var notchSize: CGSize {
        if let s = screen, hasRealNotch {
            let left = s.auxiliaryTopLeftArea?.width ?? 0
            let right = s.auxiliaryTopRightArea?.width ?? 0
            let width = max(180, s.frame.width - left - right)
            return CGSize(width: width, height: s.safeAreaInsets.top)
        }
        return CGSize(width: 220, height: 32)
    }

    /// Size of the expanded panel. The window is *always* this size (top-centre,
    /// transparent around the blob when collapsed) so the open/close grow can be a
    /// pure, smooth SwiftUI animation with no window-resize jank.
    static let expandedSize = CGSize(width: 300, height: 128)

    /// Compact size used for the transient "screenshot copied" banner.
    static let toastSize = CGSize(width: 252, height: 46)
}

/// The classic macOS notch silhouette: flat against the screen top with little
/// reverse curves at the upper corners and rounded lower corners.
struct NotchShape: Shape {
    var cornerInset: CGFloat = 8     // the small reverse curve where it meets the screen edge
    var bottomRadius: CGFloat = 12

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
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
    init(rootView: some View) {
        super.init(contentRect: NSRect(origin: .zero, size: ScreenMetrics.expandedSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true   // collapsed at launch

        let hosting = NSHostingView(rootView: rootView)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Don't let AppKit shove the window down to keep it below the menu bar —
    /// the notch lives *at* the screen edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func reposition() {
        guard let screen = ScreenMetrics.screen else { return }
        let sf = screen.frame
        let size = ScreenMetrics.expandedSize
        setFrame(NSRect(x: (sf.minX + sf.maxX) / 2 - size.width / 2,
                        y: sf.maxY - size.height,
                        width: size.width, height: size.height),
                 display: true)
    }

    func show() {
        reposition()
        orderFrontRegardless()
    }
}
