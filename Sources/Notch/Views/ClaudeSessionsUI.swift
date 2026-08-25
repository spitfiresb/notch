import SwiftUI

// MARK: - Spinner

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

// MARK: - Bottom-right corner

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
    static let stripTopInset: CGFloat = ScreenMetrics.expandedSize.height - 10 - stripHeight
    /// Where the spinner sits, in screen coordinates, given the open blob's
    /// rect (bottom-right, inside the 22 pt content inset). Mirrors NotchRootView.
    static func hitRect(inBlob blob: NSRect) -> NSRect {
        NSRect(x: blob.maxX - 22 - 28, y: blob.maxY - stripTopInset - stripHeight,
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

// MARK: - Clawd

/// Claude Code's pixel mascot, traced from the reference sprite: an 8×6
/// torso with one-pixel arm nubs, single-pixel eyes set right of centre
/// (looking where he's going) and four one-pixel legs, on a 10×7 grid.
/// `.` empty, `#` body, `o` eye. Two run frames alternate the leg pairs.
enum ClawdSprite {
    static let frames: [[String]] = [
        [
            ".########.",
            ".########.",
            "###o###o##",
            "##########",
            ".########.",
            ".########.",
            ".#....#...",
        ],
        [
            ".########.",
            ".########.",
            "###o###o##",
            "##########",
            ".########.",
            ".########.",
            "...#....#.",
        ],
    ]
    static let columns = 10
    static let rows = 7
    static let body = Color(red: 0xDE / 255, green: 0x88 / 255, blue: 0x6D / 255)
}

/// One frame of Clawd, rendered pixel-perfect at `height` points.
struct ClawdView: View {
    var frame = 0
    var height: CGFloat = 10
    static func width(forHeight h: CGFloat) -> CGFloat {
        h * CGFloat(ClawdSprite.columns) / CGFloat(ClawdSprite.rows)
    }

    var body: some View {
        Canvas { ctx, size in
            let p = size.height / CGFloat(ClawdSprite.rows)
            var bodyPath = Path()
            var eyePath = Path()
            let bitmap = ClawdSprite.frames[frame % ClawdSprite.frames.count]
            for (y, row) in bitmap.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    // Overlap neighbours by a hair so antialiasing can't leave seams.
                    let r = CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: p, height: p)
                        .insetBy(dx: -0.15, dy: -0.15)
                    if ch == "o" { eyePath.addRect(r) } else { bodyPath.addRect(r) }
                }
            }
            ctx.fill(bodyPath, with: .color(ClawdSprite.body))
            ctx.fill(eyePath, with: .color(.black))
        }
        .frame(width: Self.width(forHeight: height), height: height)
    }
}

// MARK: - Finished toast

/// Clawd sprints across the whole banner left → right — entering from beyond
/// the blob's edge and leaving past the other — while "<project> session
/// complete", centred, is painted in behind him as he passes. The notch
/// folds up shortly after he's gone. Clicking jumps to the session.
struct SessionToastView: View {
    let toast: SessionToast
    @EnvironmentObject private var store: ClaudeSessionStore
    @EnvironmentObject private var notch: NotchState
    @State private var start = Date()

    /// Notch-expand settle time before Clawd enters.
    private static let lead = 0.30
    /// Time to cross from fully outside the left edge to fully outside the right.
    private static let run = 1.7
    /// Seconds per run-cycle frame.
    private static let stride = 0.085
    /// A touch taller than the 12 pt label so he reads as a character, not a glyph.
    private static let spriteHeight: CGFloat = 15
    /// Horizontal inset NotchRootView applies to the toast content; the blob
    /// edge (where clipping happens) sits this far outside our bounds.
    private static let edgeInset: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let spriteW = ClawdView.width(forHeight: Self.spriteHeight)
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSince(start) - Self.lead
                let progress = min(max(t / Self.run, 0), 1)
                let startX = -Self.edgeInset - spriteW
                let endX = w + Self.edgeInset
                let x = startX + (endX - startX) * CGFloat(progress)
                let frame = Int(max(0, t) / Self.stride) % ClawdSprite.frames.count
                ZStack(alignment: .leading) {
                    Text(toast.message)
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(-0.1)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)          // centred in the banner
                        // Revealed up to Clawd's midline, so it trails in his wake.
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: max(0, x + spriteW / 2))
                        }
                    ClawdView(frame: frame, height: Self.spriteHeight)
                        .offset(x: x, y: frame == 1 ? -0.7 : 0)
                        .opacity(t >= 0 ? 1 : 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in
            store.focus(toast.session)
            notch.dismissToast()
        })
        .onAppear { start = Date() }
    }
}

// MARK: - Unfolded panel

/// Session rows shown in the space that opens beneath the tab.
struct SessionsPanel: View {
    @EnvironmentObject private var store: ClaudeSessionStore

    static let rowHeight: CGFloat = 35
    static let rowSpacing: CGFloat = 3
    /// Content height for `rows` sessions — what the blob grows by.
    static func height(rows: Int) -> CGFloat {
        rows == 0 ? 24 : CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing
    }

    var body: some View {
        if store.sessions.isEmpty {
            Text("No Claude sessions running")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: Self.rowSpacing) {
                        ForEach(store.ordered) { s in
                            SessionRow(session: s, now: ctx.date) { store.focus(s) }
                        }
                    }
                }
            }
        }
    }
}

extension ClaudeSession.State {
    var color: Color {
        switch self {
        case .idle:       .white.opacity(0.35)
        case .thinking:   ClaudeSpinner.orange
        case .tool:       ClaudeSpinner.orange
        case .compacting: Color(red: 0.75, green: 0.55, blue: 1.0)
        case .waiting:    ClaudeSpinner.amber
        case .done:       Color(red: 0.40, green: 0.87, blue: 0.50)
        case .failed:     Color(red: 1.0, green: 0.40, blue: 0.40)
        }
    }
    var label: String {
        switch self {
        case .idle:       "idle"
        case .thinking:   "thinking"
        case .tool:       "working"
        case .compacting: "compacting"
        case .waiting:    "needs you"
        case .done:       "done"
        case .failed:     "failed"
        }
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let now: Date
    let action: () -> Void
    @State private var hovering = false

    private var detail: String {
        if let a = session.attention { return a }
        if let a = session.activity { return a }
        if session.state == .done, let r = session.lastReply { return r }
        if let p = session.lastPrompt { return "› " + p }
        return "waiting for a prompt"
    }

    private var timer: String? {
        guard let d = session.turnDuration(at: now) else { return nil }
        let s = Int(d)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if session.isBusy || session.needsAttention {
                    ClaudeSpinner(state: session.state, size: 10)
                } else {
                    Circle().fill(session.state.color).frame(width: 6, height: 6)
                }
            }
            .frame(width: 12)
            Image(systemName: session.host.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.projectName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    if let b = session.branch {
                        Text(b)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if session.subagentCount > 0 {
                        Text("\(session.subagentCount) agent\(session.subagentCount == 1 ? "" : "s")")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Text(session.state.label)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(session.state.color)
                    if let timer {
                        Text(timer)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .monospacedDigit()
                    }
                }
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: SessionsPanel.rowHeight)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.white.opacity(hovering ? 0.10 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Same first-click-reliable gesture as the settings gear (see NotchRootView).
        .gesture(DragGesture(minimumDistance: 0).onEnded { v in
            if abs(v.translation.width) < 6, abs(v.translation.height) < 6 { action() }
        })
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
