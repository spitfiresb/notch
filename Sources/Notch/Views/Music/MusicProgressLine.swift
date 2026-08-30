import SwiftUI

/// Slim, draggable scrubber. Ticks live via `TimelineView` between data refreshes;
/// while you drag it, the labels & fill follow your finger and on release we tell the
/// player to seek to that time.
struct MusicProgressLine: View {
    let info: NowPlayingInfo
    let onSeek: (Double) -> Void

    @State private var dragFraction: CGFloat?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let total = info.duration ?? 0
            let liveElapsed = info.liveElapsed.clamped(to: 0...max(total, 0))
            let liveFraction: CGFloat = total > 0 ? CGFloat(liveElapsed / total) : 0
            let displayFraction = dragFraction ?? liveFraction
            let displaySecs = Double(displayFraction) * total

            // Both labels are derived from the SAME integer second, so they always
            // tick in the same frame. Rounding each side independently would make
            // them flip at different fractions of a second (durations are rarely
            // whole numbers), which reads as the two clocks running out of step.
            let totalSecs = max(0, Int(total.rounded()))
            let elapsedSecs = min(max(0, Int(displaySecs)), totalSecs)
            let remainingSecs = totalSecs - elapsedSecs

            HStack(spacing: 7) {
                // Both labels reserve the width of the longest string they can ever
                // show for this track (monospaced digits ⇒ that's the full duration),
                // so nothing clips on hour-long podcasts and the bar never jitters as
                // the digits tick. The scrubber soaks up whatever is left.
                timeLabel(format(elapsedSecs),
                          widest: format(totalSecs),
                          alignment: .leading)

                scrubber(fraction: displayFraction, totalSeconds: total)

                timeLabel("-\(format(remainingSecs))",
                          widest: "-\(format(totalSecs))",
                          alignment: .trailing)
            }
        }
        .opacity(info.duration ?? 0 > 0 ? 1 : 0.35)
    }

    private static let timeFont = Font.system(size: 9, weight: .medium).monospacedDigit()

    private func timeLabel(_ text: String, widest: String, alignment: Alignment) -> some View {
        Text(widest)
            .font(Self.timeFont)
            .hidden()
            .overlay(alignment: alignment) {
                Text(text)
                    .font(Self.timeFont)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize()
            }
            .fixedSize()
    }

    private func scrubber(fraction: CGFloat, totalSeconds total: Double) -> some View {
        // The bar gets noticeably thicker on hover *or* while dragging.
        let expanded = hovering || dragFraction != nil
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                // Tall transparent layer = generous hit area; the visible bar is thin.
                Color.clear.contentShape(Rectangle())
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(info.accentColor ?? .white)
                        .frame(width: g.size.width * fraction)
                }
                .frame(height: expanded ? 5 : 2.5)
                .animation(.easeOut(duration: 0.14), value: expanded)
            }
            .trackedHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard total > 0 else { return }
                        dragFraction = clamp01(v.location.x / g.size.width)
                    }
                    .onEnded { v in
                        guard total > 0 else { dragFraction = nil; return }
                        let f = clamp01(v.location.x / g.size.width)
                        onSeek(Double(f) * total)
                        // Hand back to the live tick *after* the manager has settled
                        // the optimistic state so the bar doesn't snap.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            dragFraction = nil
                        }
                    }
            )
        }
        .frame(height: 14)
    }

    private func clamp01(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }

    private func format(_ seconds: Int) -> String {
        let v = max(0, seconds)
        if v >= 3600 {
            return String(format: "%d:%02d:%02d", v / 3600, (v % 3600) / 60, v % 60)
        }
        return String(format: "%d:%02d", v / 60, v % 60)
    }
}

private extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
