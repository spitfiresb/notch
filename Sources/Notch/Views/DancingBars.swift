import SwiftUI

/// Six bars whose heights track either real audio (via `AudioMeter`'s six band levels,
/// low frequencies first) or, when no tap signal is available, a continuous sine wiggle.
/// When paused, the bars freeze at a low resting height.
struct DancingBars: View {
    var color: Color = .white
    var isPlaying: Bool = true

    @EnvironmentObject private var meter: AudioMeter

    /// Low resting height when paused / silent — short, equal capsules. Sits a touch
    /// above the playing-state floor (0.10) so pausing the music doesn't visually
    /// pop the bars upward.
    private static let restHeight: CGFloat = 0.14
    var barWidth: CGFloat = 1.8
    var spacing: CGFloat = 1.3
    private static let count = AudioMeter.bandCount

    var body: some View {
        if !isPlaying {
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<Self.count, id: \.self) { _ in
                    bar(height: Self.restHeight)
                }
            }
        } else if meter.isRunning {
            // Real audio — re-renders every time the meter publishes new levels.
            // The envelope follower in AudioMeter handles the shape of the motion
            // (per-band attack/release); this short easeOut just interpolates
            // between successive publishes so the bar visibly travels through
            // middle values at frame rate instead of stepping in discrete jumps.
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<Self.count, id: \.self) { i in
                    bar(height: meter.bars[i])
                }
            }
            .animation(.easeOut(duration: 0.07), value: meter.bars)
        } else {
            // Fallback: synthesized wiggle so playing-without-permission still feels alive.
            // Capped at 30 fps — `.animation` uncapped runs at display refresh
            // (120 Hz on ProMotion) for a wiggle nobody can see that fast.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<Self.count, id: \.self) { i in
                        bar(height: scale(t, phase: Double(i) * 1.1))
                    }
                }
            }
        }
    }

    private func bar(height: CGFloat) -> some View {
        // No floor clamp here — callers pass the value they want (paused uses
        // restHeight, real audio uses the meter's 0.10..1.0 range, fallback uses
        // its own range). A `max()` here would silently squash the meter's floor.
        Capsule(style: .continuous)
            .fill(color)
            .frame(width: barWidth)
            .frame(maxHeight: .infinity)
            .scaleEffect(y: height, anchor: .center)
    }

    /// Two summed sines at different frequencies → an organic, non-repeating wiggle.
    private func scale(_ t: Double, phase: Double) -> CGFloat {
        let a = sin(t * 5.2 + phase)        * 0.5 + 0.5
        let b = sin(t * 9.7 + phase * 2.1)  * 0.5 + 0.5
        return CGFloat(0.22 + (a * 0.6 + b * 0.4) * 0.78)
    }
}


/// `DancingBars` turned to run along an upright pill: the six bars stack
/// top-to-bottom and each one reaches sideways, so on a side dock the meter
/// uses the pill's length instead of being squeezed into its width.
struct LengthwiseBars: View {
    var color: Color = .white
    var isPlaying: Bool = true
    /// How far a full bar reaches (across the pill).
    var reach: CGFloat = 20
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 3
    /// Bars grow from their baseline; a quarter turn clockwise puts that on
    /// the left. On the right edge turn the other way so they still grow out
    /// from the screen edge.
    var fromRight = false

    private var thickness: CGFloat { CGFloat(AudioMeter.bandCount) * barWidth + CGFloat(AudioMeter.bandCount - 1) * spacing }

    var body: some View {
        DancingBars(color: color, isPlaying: isPlaying, barWidth: barWidth, spacing: spacing)
            .frame(width: thickness, height: reach)
            .rotationEffect(.degrees(fromRight ? -90 : 90))
            .frame(width: reach, height: thickness)
    }
}
