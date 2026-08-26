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
/// `.` empty, `#` body, `o`/`x` eye colour.
enum ClawdSprite {
    /// Run cycle: alternate leg pairs.
    static let run: [[String]] = [
        [".########.", ".########.", "###o###o##", "##########", ".########.", ".########.", ".#....#..."],
        [".########.", ".########.", "###o###o##", "##########", ".########.", ".########.", "...#....#."],
    ]
    /// Standing: all four legs down.
    static let stand: [String] =
        [".########.", ".########.", "###o###o##", "##########", ".########.", ".########.", ".#.#..#.#."]
    /// Knocked out: same solid body at 2× resolution so each eye is a 4×4 X.
    static let down: [String] = [
        "..################..",
        "..################..",
        "..################..",
        "..###x##x####x##x#..",
        "######xx######xx####",
        "######xx######xx####",
        "#####x##x####x##x###",
        "..################..",
        "..################..",
        "..################..",
        "..################..",
        "..################..",
        "..##..##....##..##..",
        "..##..##....##..##..",
    ]
    static let columns = 10
    static let rows = 7
    static let body = Color(red: 0xDE / 255, green: 0x88 / 255, blue: 0x6D / 255)

    /// 3×5 speech glyphs shown over his head.
    static let bang: [String] = [".#.", ".#.", ".#.", "...", ".#."]
    static let query: [String] = ["##.", "..#", ".#.", "...", ".#."]

    static func width(forHeight h: CGFloat) -> CGFloat { h * CGFloat(columns) / CGFloat(rows) }
}

/// A bitmap of `.`/`#`/`o`/`x` rows rendered pixel-perfect at `height` points.
struct PixelBitmap: View {
    let bitmap: [String]
    var color: Color = ClawdSprite.body
    var eye: Color = .black
    var height: CGFloat

    private var width: CGFloat {
        height * CGFloat(bitmap.first?.count ?? 1) / CGFloat(bitmap.count)
    }

    var body: some View {
        Canvas { ctx, size in
            let p = size.height / CGFloat(bitmap.count)
            var bodyPath = Path()
            var eyePath = Path()
            for (y, row) in bitmap.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    // Overlap neighbours by a hair so antialiasing can't leave seams.
                    let r = CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: p, height: p)
                        .insetBy(dx: -0.15, dy: -0.15)
                    if ch == "o" || ch == "x" { eyePath.addRect(r) } else { bodyPath.addRect(r) }
                }
            }
            ctx.fill(bodyPath, with: .color(color))
            ctx.fill(eyePath, with: .color(eye))
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Session toast

/// One Clawd banner per session event, choreographed by `toast.kind`:
/// - complete:   sprints the full width, the label painted in behind him.
/// - permission: trots in, stops beside the label, hops with a blinking "!",
///               then trots off.
/// - question:   same, but rocks side to side under a "?".
/// - failed:     trots in, trips and tips onto his side with X eyes, fades.
/// Every horizontal move is at the same cruise speed. Clicking jumps to the
/// session's terminal.
struct SessionToastView: View {
    let toast: SessionToast
    @EnvironmentObject private var store: ClaudeSessionStore
    @EnvironmentObject private var notch: NotchState
    @State private var start = Date()

    /// Notch-expand settle time before Clawd enters.
    private static let lead = 0.30
    /// Full-width crossing time (complete toast) — defines the cruise speed.
    private static let run = 1.7
    /// Seconds per run-cycle frame.
    private static let stride = 0.085
    /// A touch taller than the 12 pt label so he reads as a character, not a glyph.
    private static let spriteHeight: CGFloat = 15
    /// Horizontal inset NotchRootView applies to the toast content; the blob
    /// edge (where clipping happens) sits this far outside our bounds.
    private static let edgeInset: CGFloat = 14
    /// Gap between Clawd and the label when he stops beside it.
    private static let gap: CGFloat = 8
    private static let amber = Color(red: 1.0, green: 0.68, blue: 0.20)
    private static let red   = Color(red: 1.0, green: 0.42, blue: 0.42)

    private static let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    private var labelColor: Color {
        switch toast.kind {
        case .complete:              .white
        case .permission, .question: Self.amber
        case .failed:                Self.red
        }
    }

    /// Measured label width so the Clawd + label group can be centred.
    private var labelWidth: CGFloat {
        (toast.message as NSString).size(withAttributes: [.font: Self.labelFont, .kern: -0.1]).width
    }

    /// Everything the timeline needs to draw one instant.
    private struct Pose {
        var x: CGFloat
        var bitmap: [String]
        var bob: CGFloat = 0
        var rot: Double = 0
        var show = true
        var opacity: Double = 1
        var glyph: [String]? = nil
        var textLeft: CGFloat
        /// x up to which the label is revealed (nil = fully shown).
        var reveal: CGFloat?
    }

    private func pose(at t: TimeInterval, width w: CGFloat) -> Pose {
        let spriteW = ClawdSprite.width(forHeight: Self.spriteHeight)
        let inset = Self.edgeInset
        let speed = (w + 2 * inset + spriteW) / Self.run          // pt per second
        let dur = { (px: CGFloat) in TimeInterval(px / speed) }
        let entryX = -inset - spriteW
        let exitX = w + inset
        func runFrame(_ since: TimeInterval) -> (bitmap: [String], bob: CGFloat) {
            let f = Int(max(0, since) / Self.stride) % ClawdSprite.run.count
            return (ClawdSprite.run[f], f == 1 ? -0.7 : 0)
        }

        if toast.kind == .complete {
            let p = min(max((t - Self.lead) / Self.run, 0), 1)
            let x = entryX + (exitX - entryX) * CGFloat(p)
            let rf = runFrame(t - Self.lead)
            return Pose(x: x, bitmap: rf.bitmap, bob: rf.bob, show: t >= Self.lead,
                        textLeft: (w - labelWidth) / 2, reveal: x + spriteW / 2)
        }

        // Stop-in-the-middle variants: Clawd + gap + label centred as a group.
        let groupW = spriteW + Self.gap + labelWidth
        let stopX = (w - groupW) / 2
        let textLeft = stopX + spriteW + Self.gap
        let inDur = dur(stopX - entryX)
        let arriveT = Self.lead + inDur

        if t < arriveT {
            let p = min(max((t - Self.lead) / inDur, 0), 1)
            let x = entryX + (stopX - entryX) * CGFloat(p)            // linear: cruise, then stop
            let rf = runFrame(t - Self.lead)
            return Pose(x: x, bitmap: rf.bitmap, bob: rf.bob, show: t >= Self.lead,
                        textLeft: textLeft, reveal: x + spriteW / 2)
        }

        switch toast.kind {
        case .failed:
            let fallT = arriveT + 0.12, fadeT = 4.0
            let fp = min(max((t - fallT) / 0.25, 0), 1)
            let rot = 90 * (1 - pow(1 - fp, 2))                         // tip over, ease-out
            let opacity = t > fadeT ? max(0, 1 - (t - fadeT) / 0.4) : 1
            return Pose(x: stopX, bitmap: fp > 0.6 ? ClawdSprite.down : ClawdSprite.stand,
                        rot: rot, opacity: opacity, textLeft: textLeft, reveal: nil)
        default:
            let leaveT = 4.4
            if t < leaveT {
                let since = t - arriveT
                if toast.kind == .permission {
                    let hop = since.truncatingRemainder(dividingBy: 0.7) / 0.7   // little hop every 0.7 s
                    let bob: CGFloat = hop < 0.35 ? CGFloat(-3 * sin(hop / 0.35 * .pi)) : 0
                    let blinkOn = Int(since / 0.35) % 2 == 0
                    return Pose(x: stopX, bitmap: ClawdSprite.stand, bob: bob,
                                glyph: blinkOn ? ClawdSprite.bang : nil, textLeft: textLeft, reveal: nil)
                } else {
                    let rot = sin(since / 0.9 * 2 * .pi) * 7                 // slow rock
                    return Pose(x: stopX, bitmap: ClawdSprite.stand, rot: rot,
                                glyph: ClawdSprite.query, textLeft: textLeft, reveal: nil)
                }
            }
            let outDur = dur(exitX - stopX)
            let p = min((t - leaveT) / outDur, 1)
            let x = stopX + (exitX - stopX) * CGFloat(p)
            let rf = runFrame(t)
            return Pose(x: x, bitmap: rf.bitmap, bob: rf.bob, textLeft: textLeft, reveal: nil)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let spriteH = Self.spriteHeight
            let spriteW = ClawdSprite.width(forHeight: spriteH)
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSince(start)
                let p = pose(at: t, width: w)
                let revealW: CGFloat = p.reveal.map { max(0, $0 - p.textLeft) } ?? (labelWidth + 4)
                ZStack(alignment: .leading) {
                    Text(toast.message)
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(-0.1)
                        .foregroundStyle(labelColor)
                        .lineLimit(1)
                        .fixedSize()
                        .mask(alignment: .leading) { Rectangle().frame(width: revealW) }
                        .offset(x: p.textLeft)
                        .opacity(p.opacity)
                    PixelBitmap(bitmap: p.bitmap, height: spriteH)
                        // The "down" bitmap is 2×; PixelBitmap sizes by row count.
                        .frame(width: spriteW, height: spriteH)
                        .rotationEffect(.degrees(p.rot), anchor: toast.kind == .failed ? .bottomTrailing : .center)
                        .offset(x: p.x, y: p.bob)
                        .opacity(p.show ? p.opacity : 0)
                    if let glyph = p.glyph {
                        PixelBitmap(bitmap: glyph, color: labelColor, height: 5)
                            .offset(x: p.x + spriteW / 2 - 1.5, y: -(spriteH / 2 + 4.5) + p.bob)
                    }
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
