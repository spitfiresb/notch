import SwiftUI

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
            // Capped at 40 fps: uncapped .animation runs at display refresh
            // (120 Hz on ProMotion), and every frame relayouts the hosting
            // view. At the ~220 pt/s cruise that's ~5 pt a frame — quantized
            // motion that suits a pixel sprite whose run cycle steps at 85 ms.
            TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { ctx in
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
