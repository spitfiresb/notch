import SwiftUI

/// Side transport (⏮ / ⏭) — slightly grey by default, brightens & scales up on hover.
/// Shared timing: 100 ms press, 280 ms release, 200 ms hover.
struct TransportButton: View {
    enum Glyph { case symbol(String), text(String), playPause(Bool) }
    let glyph: Glyph
    let size: CGFloat
    let enabled: Bool
    let action: () -> Void

    init(symbol: String, size: CGFloat, enabled: Bool, action: @escaping () -> Void) {
        self.init(glyph: .symbol(symbol), size: size, enabled: enabled, action: action)
    }

    init(glyph: Glyph, size: CGFloat, enabled: Bool, action: @escaping () -> Void) {
        self.glyph = glyph; self.size = size; self.enabled = enabled; self.action = action
    }

    @State private var hovering = false
    @State private var pressed = false

    /// Text glyphs ("1.5x") run wider than a symbol; give them room to grow so the
    /// row doesn't reflow when the speed changes.
    private var width: CGFloat {
        if case .text = glyph { return size + 22 }
        return size + 12
    }

    @ViewBuilder private var label: some View {
        switch glyph {
        case .symbol(let name): Image(systemName: name)
        case .playPause(let isPlaying):
            PlayPauseGlyph(progress: isPlaying ? 1 : 0)
                .frame(width: size, height: size)
                .animation(.easeInOut(duration: 0.28), value: isPlaying)
        case .text(let s): Text(s).monospacedDigit().lineLimit(1).fixedSize()
        }
    }

    var body: some View {
        label
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white.opacity(hovering ? 1 : 0.55))
            .frame(width: width, height: size + 8)
            .contentShape(Rectangle())
            .scaleEffect(scale)
            // All transport controls use the same press and release duration.
            .animation(pressed
                       ? .easeOut(duration: 0.10)
                       : .easeOut(duration: 0.28),
                       value: pressed)
            .animation(.easeInOut(duration: 0.20), value: hovering)
            .opacity(enabled ? 1 : 0.3)
            .trackedHover { if enabled { hovering = $0 } }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { _ in if enabled && !pressed { pressed = true } }
                    .onEnded { v in
                        pressed = false
                        guard enabled else { return }
                        let bounds = CGRect(x: 0, y: 0, width: width, height: size + 8)
                        if bounds.contains(v.location) { action() }
                    }
            )
    }

    private var scale: CGFloat {
        guard enabled else { return 1 }
        if pressed { return 0.78 }
        if hovering { return 1.20 }
        return 1.0
    }
}

/// Both the compact and expanded players share the same press/release motion.
struct PlayPauseButton: View {
    let isPlaying: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        TransportButton(glyph: .playPause(isPlaying), size: 17, enabled: enabled, action: action)
            .frame(width: 30, height: 30)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

/// Two adjoining pieces of one triangle morph into two pause bars. No layered
/// symbols or fading copies, so there is no old glyph left behind during a swap.
private struct PlayPauseGlyph: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let play: [[CGPoint]] = [
            [CGPoint(x: 0.18, y: 0.08), CGPoint(x: 0.48, y: 0.26),
             CGPoint(x: 0.48, y: 0.74), CGPoint(x: 0.18, y: 0.92)],
            [CGPoint(x: 0.48, y: 0.26), CGPoint(x: 0.88, y: 0.5),
             CGPoint(x: 0.88, y: 0.5), CGPoint(x: 0.48, y: 0.74)]
        ]
        let pause: [[CGPoint]] = [
            [CGPoint(x: 0.18, y: 0.08), CGPoint(x: 0.40, y: 0.08),
             CGPoint(x: 0.40, y: 0.92), CGPoint(x: 0.18, y: 0.92)],
            [CGPoint(x: 0.60, y: 0.08), CGPoint(x: 0.82, y: 0.08),
             CGPoint(x: 0.82, y: 0.92), CGPoint(x: 0.60, y: 0.92)]
        ]
        var path = Path()
        for piece in 0..<2 {
            for vertex in 0..<4 {
                let a = play[piece][vertex], b = pause[piece][vertex]
                let point = CGPoint(x: rect.minX + (a.x + (b.x - a.x) * progress) * rect.width,
                                    y: rect.minY + (a.y + (b.y - a.y) * progress) * rect.height)
                if vertex == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
        return path
    }
}
