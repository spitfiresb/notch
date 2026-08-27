import SwiftUI

/// Side transport (⏮ / ⏭) — slightly grey by default, brightens & scales up on hover.
/// Hover and release use springs (gentle bounce / pop), press-down is a snappy ease.
struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white.opacity(hovering ? 1 : 0.55))
            .frame(width: size + 12, height: size + 8)
            .contentShape(Rectangle())
            .scaleEffect(scale)
            // press DOWN: snappy ease; press UP: spring with overshoot for the iOS-style "pop".
            .animation(pressed
                       ? .easeOut(duration: 0.12)
                       : .spring(response: 0.68, dampingFraction: 0.5),
                       value: pressed)
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: hovering)
            .opacity(enabled ? 1 : 0.3)
            .onHover { if enabled { hovering = $0 } }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { _ in if enabled && !pressed { pressed = true } }
                    .onEnded { v in
                        pressed = false
                        guard enabled else { return }
                        let bounds = CGRect(x: 0, y: 0, width: size + 12, height: size + 8)
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

/// Play/pause built from a custom press gesture (no `Button` — avoids macOS's default
/// pressed-state grey tint that was layering over our own animation). Behaviour:
///   • hover → button scales up ~1.1
///   • press → snaps down to 0.82 in ~50ms (almost instant)
///   • release → action fires, the icon cross-fade kicks in, and the scale grows back
///               to its current target (1.0 or 1.1 if still hovering) — all in sync.
struct PlayPauseButton: View {
    let isPlaying: Bool
    let enabled: Bool
    let action: () -> Void

    /// What's actually drawn; only updated on release so the icon swap is paired
    /// with the grow-back, not the depress.
    @State private var renderIsPlaying = false
    @State private var hovering = false
    @State private var pressed = false

    private let size: CGFloat = 30

    var body: some View {
        // One simple cross-fade — the icons don't scale individually (that was reading
        // as a second motion on top of the button's own scale). Pure opacity swap.
        ZStack {
            Image(systemName: "play.fill").opacity(renderIsPlaying ? 0 : 1)
            Image(systemName: "pause.fill").opacity(renderIsPlaying ? 1 : 0)
        }
        // Grey at rest, brightens on hover — matches the side transport buttons.
        .foregroundStyle(.white.opacity(hovering ? 1 : 0.55))
        .font(.system(size: 17, weight: .medium))
        .animation(.easeOut(duration: 0.32), value: renderIsPlaying)
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .scaleEffect(scale)
        // Snappy press-down, bouncy spring release — Apple-style click pop.
        .animation(pressed
                   ? .easeOut(duration: 0.12)
                   : .spring(response: 0.72, dampingFraction: 0.5),
                   value: pressed)
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: hovering)
        .opacity(enabled ? 1 : 0.3)
        .onHover { if enabled { hovering = $0 } }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { _ in if enabled && !pressed { pressed = true } }
                .onEnded { v in
                    pressed = false
                    guard enabled else { return }
                    let bounds = CGRect(x: 0, y: 0, width: size, height: size)
                    if bounds.contains(v.location) {
                        action()
                        // Flip the render state in the SAME runloop tick as `pressed=false`
                        // so the icon cross-fade starts the instant the button starts
                        // growing back — no hesitation while we wait for `.onChange` to
                        // fire after the parent's re-render.
                        renderIsPlaying.toggle()
                    }
                }
        )
        .onAppear { renderIsPlaying = isPlaying }
        .onChange(of: isPlaying) { _, new in
            // Catch external changes (poll) — local toggle above already synced for taps.
            if renderIsPlaying != new { renderIsPlaying = new }
        }
    }

    private var scale: CGFloat {
        guard enabled else { return 1 }
        if pressed { return 0.82 }
        if hovering { return 1.15 }
        return 1.0
    }
}
