import SwiftUI

/// Spotify's own save affordance, one button: grey ⊕ when the track isn't saved
/// anywhere (click = save to Liked Songs, plus morphs into the green check),
/// green ✓ when it's Liked or in any of your playlists (click = show where).
/// Before login it leads into the connect flow.
struct SaveButton: View {
    @EnvironmentObject private var spotify: SpotifyLibrary
    let enabled: Bool
    /// Opens the "Saved in" panel (also hosts the connect / error states).
    let showList: () -> Void

    @State private var hovering = false
    @State private var pressed = false
    /// Incremented per like — each bump replays the confetti burst.
    @State private var burst = 0

    static let spotifyGreen = Color(red: 0.12, green: 0.84, blue: 0.38)

    private var saved: Bool { spotify.state == .connected && spotify.membership.hasAny }
    private let size: CGFloat = 13

    var body: some View {
        Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(saved ? Self.spotifyGreen : .white.opacity(hovering ? 1 : 0.55))
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: saved)
            .frame(width: size + 12, height: size + 8)
            .overlay(ConfettiBurst(trigger: burst, color: Self.spotifyGreen))
            .contentShape(Rectangle())
            .scaleEffect(pressed ? 0.78 : (hovering ? 1.2 : 1))
            .animation(pressed ? .easeOut(duration: 0.12)
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
                        guard bounds.contains(v.location) else { return }
                        if spotify.state == .connected, !saved, spotify.membership.trackID != nil {
                            spotify.setLiked(true)   // ⊕ = save to Liked Songs
                            burst += 1
                            Haptics.tick()
                        } else {
                            showList()
                        }
                    }
            )
    }
}

/// Spotify's like-burst: a ring of little green dots that shoot outward from
/// the button and fade. Replays every time `trigger` changes. Driven by a
/// TimelineView clock rather than `withAnimation` — a reset-then-animate on the
/// same state in one update nets out to "no change" and never plays.
private struct ConfettiBurst: View {
    let trigger: Int
    let color: Color

    @State private var startedAt: Date?

    private static let duration = 0.42

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: startedAt == nil)) { ctx in
            let p: CGFloat = {
                guard let s = startedAt else { return 1 }
                return CGFloat(min(1, ctx.date.timeIntervalSince(s) / Self.duration))
            }()
            let eased = 1 - pow(1 - p, 3)   // ease-out: fast launch, gentle landing
            ZStack {
                ForEach(0..<16, id: \.self) { i in
                    let angle = (Double(i) + 0.5) / 16 * 2 * .pi
                    let radius: CGFloat = 13 + CGFloat((i * 7) % 3) * 3   // slight per-dot variance
                    let dot: CGFloat = i.isMultiple(of: 2) ? 1.2 : 0.9
                    // Gravity: the radial launch decelerates (eased) while a
                    // t² drop accumulates, so dots arc outward then fall away.
                    let drop = p * p * (2 + CGFloat((i * 5) % 4))
                    Circle()
                        .fill(color)
                        .frame(width: dot, height: dot)
                        .offset(x: cos(angle) * radius * eased,
                                y: sin(angle) * radius * eased + drop)
                        // Solid for most of the flight, quick fade at the very end.
                        .opacity(p < 0.75 ? 1 : Double(max(0, 1 - (p - 0.75) / 0.25)))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            startedAt = Date()
            // Pause the timeline once the burst has fully played out.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + 0.1) {
                if let s = startedAt, Date().timeIntervalSince(s) > Self.duration {
                    startedAt = nil
                }
            }
        }
    }
}
