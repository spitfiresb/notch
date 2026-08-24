import SwiftUI

/// Live Claude Code sessions. Deliberately plain — a functional list so the
/// plumbing can be exercised; the real UI treatment comes later.
struct SessionsTabView: View {
    @EnvironmentObject private var store: ClaudeSessionStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        if !settings.claudeSessionsEnabled {
            EmptyTabPlaceholder(symbol: "terminal", text: "Enable Claude sessions in Settings")
        } else if store.sessions.isEmpty {
            EmptyTabPlaceholder(symbol: "terminal",
                                text: store.hooksInstalled ? "No Claude sessions running"
                                                           : "Hooks not installed — check Settings")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(store.ordered) { s in
                        SessionRow(session: s) { store.focus(s) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let action: () -> Void
    @State private var hovering = false

    private var color: Color {
        switch session.state {
        case .idle:       return .white.opacity(0.35)
        case .thinking:   return .blue
        case .tool:       return .cyan
        case .compacting: return .purple
        case .waiting:    return .orange
        case .done:       return .green
        case .failed:     return .red
        }
    }

    private var stateLabel: String {
        switch session.state {
        case .idle:       return "idle"
        case .thinking:   return "thinking"
        case .tool:       return "running"
        case .compacting: return "compacting"
        case .waiting:    return "needs you"
        case .done:       return "done"
        case .failed:     return "failed"
        }
    }

    private var detail: String {
        if let a = session.attention { return a }
        if let a = session.activity { return a }
        if session.state == .done, let r = session.lastReply { return r }
        if let p = session.lastPrompt { return "› " + p }
        return "—"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .modifier(Pulse(active: session.isBusy || session.state == .waiting))
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
                    Text(stateLabel)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(color)
                    if session.subagentCount > 0 {
                        Text("×\(session.subagentCount)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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

/// Slow opacity breathe for the status dot while a session is live.
private struct Pulse: ViewModifier {
    let active: Bool
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(active ? (on ? 1 : 0.35) : 1)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                       value: on)
            .onAppear { on = true }
    }
}

struct EmptyTabPlaceholder: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.white.opacity(0.3))
            Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
