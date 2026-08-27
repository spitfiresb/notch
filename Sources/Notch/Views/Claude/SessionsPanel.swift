import SwiftUI

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
