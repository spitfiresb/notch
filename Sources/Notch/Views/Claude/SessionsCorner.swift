import SwiftUI

/// The Claude CLI's own "thinking" glyph cycle (· ✢ ✳ ∗ ✻ ✽) in Claude orange.
/// Amber and static-ish when a session is blocked on you instead of working.
struct ClaudeSpinner: View {
    var state: ClaudeSession.State = .tool
    var size: CGFloat = 12

    private static let frames = ["·", "✢", "✳", "∗", "✻", "✽"]
    static let orange = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let amber  = Color(red: 1.0, green: 0.68, blue: 0.20)

    private var blocked: Bool { state == .waiting || state == .failed }

    var body: some View {
        let step = blocked ? 1.2 : 0.30
        TimelineView(.periodic(from: .now, by: step)) { ctx in
            let tick = Int(ctx.date.timeIntervalSinceReferenceDate / step)
            Text(blocked ? (tick % 2 == 0 ? "✻" : "✽") : Self.frames[tick % Self.frames.count])
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(blocked ? Self.amber : Self.orange)
                .frame(width: size + 2, height: size + 2)
        }
    }
}

/// The spinner parked in the empty bottom-right corner of the open notch.
/// Hovering it unfolds `SessionsPanel` beneath the tab; the hover watcher in
/// AppDelegate folds it back when the cursor returns to the tab area above.
struct SessionsCorner: View {
    @EnvironmentObject private var claude: ClaudeSessionStore
    @EnvironmentObject private var notch: NotchState

    /// Height of the strip along the bottom of the tab area that the spinner
    /// lives in. The hover watcher treats anything above it as "back in the tab".
    /// Same height as the music tab's transport row so the spinner sits on
    /// the ⏮ ⏯ ⏭ centreline.
    static let stripHeight: CGFloat = 30
    /// Distance from the top of the open blob to the top of the strip: the
    /// transport row is the last thing in the tab, above its 10 pt bottom pad.
    static func stripTopInset(for dock: NotchDock) -> CGFloat {
        ScreenMetrics.expandedSize(for: dock).height - 10 - stripHeight
    }
    /// Where the spinner sits, in screen coordinates, given the open blob's
    /// rect: the bottom corner on the blob's free side (right, except when the
    /// notch is docked to the right edge), inside the 22 pt content inset.
    /// Mirrors NotchRootView.
    static func hitRect(inBlob blob: NSRect, dock: NotchDock) -> NSRect {
        let x = dock == .right ? blob.minX + 22 - 4 : blob.maxX - 22 - 28
        return NSRect(x: x, y: blob.maxY - stripTopInset(for: dock) - stripHeight,
                      width: 32, height: stripHeight)
    }

    var body: some View {
        ZStack {
            if claude.anyActive {
                ClaudeSpinner(state: claude.headlineState, size: 14)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: 24, height: Self.stripHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside, claude.anyActive, !notch.sessionsPanelExpanded {
                notch.sessionsPanelExpanded = true
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: claude.anyActive)
        .onChange(of: claude.anyActive) { _, active in
            if !active { notch.sessionsPanelExpanded = false }
        }
    }
}
