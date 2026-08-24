import SwiftUI

// MARK: - Shared bits

extension ClaudeSession.State {
    var color: Color {
        switch self {
        case .idle:       .white.opacity(0.35)
        case .thinking:   Color(red: 0.45, green: 0.62, blue: 1.0)
        case .tool:       Color(red: 0.35, green: 0.85, blue: 0.95)
        case .compacting: Color(red: 0.75, green: 0.55, blue: 1.0)
        case .waiting:    Color(red: 1.0, green: 0.68, blue: 0.20)
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

/// Sessions grouped by host app, hosts in a stable order.
private func groupedByHost(_ sessions: [ClaudeSession]) -> [(host: ClaudeSession.Host, sessions: [ClaudeSession])] {
    let order: [ClaudeSession.Host] = [.vscode, .terminal, .other]
    return order.compactMap { h in
        let list = sessions.filter { $0.host == h }
        return list.isEmpty ? nil : (h, list)
    }
}

/// Slow opacity breathe while a session is live.
private struct Pulse: ViewModifier {
    let active: Bool
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(active ? (on ? 1 : 0.3) : 1)
            .animation(active ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true) : .default,
                       value: on)
            .onAppear { on = true }
    }
}

private struct StatePip: View {
    let session: ClaudeSession
    var size: CGFloat = 5
    var body: some View {
        Circle()
            .fill(session.state.color)
            .frame(width: size, height: size)
            .modifier(Pulse(active: session.isBusy || session.state == .waiting))
    }
}

private struct SizeKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Collapsed pill cluster

/// `</> ●●  >_ ●` — one host glyph per app, one pip per session in it.
/// Publishes its trailing edge (relative to the pill's content inset) to
/// `NotchState.sessionClusterWidth` so the hover watcher can aim hover-opens
/// at the session detail.
struct SessionCluster: View {
    @EnvironmentObject private var store: ClaudeSessionStore
    @EnvironmentObject private var notch: NotchState

    private var groups: [(host: ClaudeSession.Host, sessions: [ClaudeSession])] {
        groupedByHost(store.ordered)
    }

    var body: some View {
        HStack(spacing: 7) {
            ForEach(groups, id: \.host) { g in
                HStack(spacing: 3) {
                    Image(systemName: g.host.symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                    HStack(spacing: 2.5) {
                        ForEach(g.sessions) { s in StatePip(session: s) }
                    }
                }
            }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: SizeKey.self, value: g.frame(in: .named("peek")).maxX)
        })
        .onPreferenceChange(SizeKey.self) { maxX in
            let w = groups.isEmpty ? 0 : maxX
            if notch.sessionClusterWidth != w { notch.sessionClusterWidth = w }
        }
        .animation(.easeOut(duration: 0.25), value: store.sessions.map(\.id))
    }
}

// MARK: - Hover detail

/// What the open notch shows when you hovered in over the cluster: one row per
/// session with a live turn timer. Click a row to jump to its terminal.
struct SessionDetailView: View {
    @EnvironmentObject private var store: ClaudeSessionStore

    var body: some View {
        if store.sessions.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 20)).foregroundStyle(.white.opacity(0.3))
                Text("No Claude sessions").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(store.ordered) { s in
                            SessionRow(session: s, now: ctx.date) { store.focus(s) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            StatePip(session: session, size: 6)
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

// MARK: - Toast

/// "notch finished ✓" / "notch needs you !" — mirrors the screenshot banner's
/// cascade + stroke-in choreography. Click jumps to the session's terminal.
struct SessionToastView: View {
    let toast: SessionToast
    @EnvironmentObject private var store: ClaudeSessionStore
    @EnvironmentObject private var notch: NotchState

    private static let lead = 0.34
    private static let perChar = 0.018

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: toast.session.host.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
            CascadeText(text: toast.message, startDelay: Self.lead, perChar: Self.perChar)
                .font(.system(size: 12, weight: .semibold))
                .kerning(-0.1)
                .foregroundStyle(.white)
            let markDelay = Self.lead + Double(toast.message.count) * Self.perChar + 0.04
            Group {
                switch toast.kind {
                case .finished: CircleCheckmark(delay: markDelay)
                case .needsYou: CircleBang(delay: markDelay, color: ClaudeSession.State.waiting.color)
                }
            }
            .frame(width: 18, height: 18)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in
            store.focus(toast.session)
            notch.dismissToast()
        })
    }
}

/// Amber ring that sweeps around, then an exclamation mark pops in.
private struct CircleBang: View {
    var delay: Double = 0
    var color: Color = .orange
    @State private var ring: CGFloat = 0
    @State private var bang = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: ring)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("!")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(color)
                .scaleEffect(bang ? 1 : 0.3)
                .opacity(bang ? 1 : 0)
        }
        .onAppear {
            ring = 0; bang = false
            withAnimation(.easeInOut(duration: 0.42).delay(delay)) { ring = 1 }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.55).delay(delay + 0.34)) { bang = true }
        }
    }
}
