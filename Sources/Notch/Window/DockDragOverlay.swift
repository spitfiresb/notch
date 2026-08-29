import AppKit
import SwiftUI

/// What the drag overlay draws, published by `NotchDragController` on every
/// cursor tick. Coordinates are in the overlay's own SwiftUI space: origin at
/// the screen's top-left, y down.
@MainActor
final class DockDragModel: ObservableObject {
    enum Phase { case idle, dragging, settling }

    @Published var phase: Phase = .idle
    /// Where the droplet rides (the cursor, in overlay coordinates).
    @Published var cursor: CGPoint = .zero
    /// The edge the blob would land on if released now.
    @Published var target: NotchDock = .top
    /// The screen the overlay covers; ghost rects are laid out inside it.
    var screenSize: CGSize = .zero

    /// Where the collapsed pill sits for `dock`, in overlay coordinates.
    func ghostRect(for dock: NotchDock) -> CGRect {
        let size = ScreenMetrics.collapsedSize(for: dock)
        switch dock {
        case .top:
            return CGRect(x: (screenSize.width - size.width) / 2, y: 0,
                          width: size.width, height: size.height)
        case .left:
            return CGRect(x: 0, y: (screenSize.height - size.height) / 2,
                          width: size.width, height: size.height)
        case .right:
            return CGRect(x: screenSize.width - size.width, y: (screenSize.height - size.height) / 2,
                          width: size.width, height: size.height)
        }
    }
}

/// Full-screen, click-through window shown only while the notch is being
/// dragged between edges. Two things live on it: the grey outlined pill that
/// marks where the blob will land, and the black droplet riding the cursor.
/// Keeping these off the notch panel means the panel never has to move — it
/// just hides, and reappears on the new edge once the droplet has landed.
final class DockDragOverlay: NSPanel {
    let model = DockDragModel()

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: DockDragOverlayView(model: model))
    }

    override var canBecomeKey: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Cover `screen` and come to the front.
    func present(on screen: NSScreen) {
        setFrame(screen.frame, display: true)
        model.screenSize = screen.frame.size
        orderFrontRegardless()
    }
}

struct DockDragOverlayView: View {
    @ObservedObject var model: DockDragModel

    /// Free-floating droplet: a small black capsule, sized so it clearly reads as
    /// the notch picked up rather than a stray window.
    private static let dropletSize = CGSize(width: 110, height: 34)

    private var ghost: CGRect { model.ghostRect(for: model.target) }
    private var edge: Edge {
        switch model.target { case .top: .top; case .left: .leading; case .right: .trailing }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Landing ghost: the collapsed pill's silhouette, outlined in grey,
            // on whichever edge is nearest the cursor. Springs between edges.
            NotchShape(cornerInset: 8, bottomRadius: 10, edge: edge)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    NotchShape(cornerInset: 8, bottomRadius: 10, edge: edge)
                        .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )
                .frame(width: ghost.width, height: ghost.height)
                .offset(x: ghost.minX, y: ghost.minY)
                .opacity(model.phase == .dragging ? 1 : 0)
                .animation(.spring(response: 0.32, dampingFraction: 0.78), value: model.target)
                .animation(.easeOut(duration: 0.18), value: model.phase)

            // The droplet. While dragging it rides the cursor with a short
            // spring lag (what reads as weight); on release its frame springs
            // onto the ghost and the corner radius tightens to the pill's.
            RoundedRectangle(cornerRadius: model.phase == .settling ? 10 : Self.dropletSize.height / 2,
                             style: .continuous)
                .fill(.black)
                .overlay(
                    RoundedRectangle(cornerRadius: model.phase == .settling ? 10 : Self.dropletSize.height / 2,
                                     style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
                .frame(width: dropletFrame.width, height: dropletFrame.height)
                .offset(x: dropletFrame.minX, y: dropletFrame.minY)
                .opacity(model.phase == .idle ? 0 : 1)
                .animation(model.phase == .settling
                           ? .spring(response: 0.38, dampingFraction: 0.74)
                           : .spring(response: 0.16, dampingFraction: 0.82),
                           value: dropletFrame)
                .animation(.easeOut(duration: 0.12), value: model.phase == .idle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dropletFrame: CGRect {
        if model.phase == .settling { return ghost }
        return CGRect(x: model.cursor.x - Self.dropletSize.width / 2,
                      y: model.cursor.y - Self.dropletSize.height / 2,
                      width: Self.dropletSize.width, height: Self.dropletSize.height)
    }
}
