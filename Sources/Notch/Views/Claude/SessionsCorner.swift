import SwiftUI

/// Provider identity stays visible in the collapsed pill and mixed session list.
struct AgentSpinner: View {
    var provider: AgentProvider
    var state: AgentSession.State = .tool
    var size: CGFloat = 12
    var paused = false
    static let codexColor = Color(red: 0.65, green: 0.88, blue: 0.80)

    var body: some View {
        if provider == .claude {
            ClaudeSpinner(state: state, size: size, paused: paused)
        } else {
            TimelineView(.animation(minimumInterval: 0.6, paused: paused)) { context in
                let bright = paused || Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
                Text(state == .waiting || state == .failed ? "!" : ">_")
                    .font(.system(size: size * 0.85, weight: .bold, design: .monospaced))
                    .foregroundStyle(state == .waiting || state == .failed ? ClaudeSpinner.amber : Self.codexColor)
                    .opacity(bright ? 1 : 0.45)
                    .frame(width: size + 2, height: size + 2)
            }
            .accessibilityLabel("Codex \(state.label)")
        }
    }
}

/// The Claude CLI's own "thinking" glyph cycle (· ✢ ✳ ∗ ✻ ✽) in Claude orange.
/// Amber and static-ish when a session is blocked on you instead of working.
struct ClaudeSpinner: View {
    var state: AgentSession.State = .tool
    var size: CGFloat = 12
    /// Freeze the glyph clock. Pass true whenever the spinner is mounted but
    /// not actually visible (e.g. behind an `.opacity(0)`): a ticking
    /// TimelineView invalidates the whole screen-sized hosting view on every
    /// step, visible or not.
    var paused: Bool = false

    private static let frames = ["·", "✢", "✳", "∗", "✻", "✽"]
    static let orange = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let amber  = Color(red: 1.0, green: 0.68, blue: 0.20)

    private var blocked: Bool { state == .waiting || state == .failed }

    var body: some View {
        let step = blocked ? 1.2 : 0.30
        // .animation-with-interval rather than .periodic solely because
        // .periodic can't pause; the cadence is the same.
        TimelineView(.animation(minimumInterval: step, paused: paused)) { ctx in
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
    @EnvironmentObject private var agents: AgentSessionStore
    @EnvironmentObject private var notch: NotchState

    /// Height of the strip along the bottom of the tab area that the spinner
    /// lives in. The hover watcher treats anything above it as "back in the tab".
    /// Same height as the music tab's transport row so the spinner sits on
    /// the ⏮ ⏯ ⏭ centreline.
    static let stripHeight: CGFloat = 30
    /// Distance from the top of the open blob to the top of the strip: the
    /// transport row is the last thing in the tab, above its bottom pad.
    static func stripTopInset(for dock: NotchDock) -> CGFloat {
        ScreenMetrics.expandedSize(for: dock).height
            - ScreenMetrics.contentVerticalInset(for: dock) - stripHeight
    }
    /// Where the spinner sits, in screen coordinates, given the open blob's
    /// rect: the bottom-right corner inside the 22 pt content inset, on every
    /// dock. Mirrors NotchRootView.
    static func hitRect(inBlob blob: NSRect, dock: NotchDock) -> NSRect {
        return NSRect(x: blob.maxX - 22 - 28, y: blob.maxY - stripTopInset(for: dock) - stripHeight,
                      width: 32, height: stripHeight)
    }

    var body: some View {
        ZStack {
            if agents.anyActive {
                // Paused while the corner is faded out (notch closed, or a
                // toast on top) — the collapsed pill runs its own spinner
                // then, and this one would just be ticking invisibly.
                AgentSpinner(provider: agents.headlineProvider, state: agents.headlineState, size: 14,
                              paused: !notch.isOpen || notch.toast != nil)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: 24, height: Self.stripHeight)
        .contentShape(Rectangle())
        .trackedHover { inside in
            if inside, agents.anyActive, !notch.sessionsPanelExpanded {
                notch.sessionsPanelExpanded = true
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: agents.anyActive)
        .onChange(of: agents.anyActive) { _, active in
            if !active { notch.sessionsPanelExpanded = false }
        }
    }
}
