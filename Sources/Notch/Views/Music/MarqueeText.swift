import SwiftUI

/// Single-line text that scrolls Spotify-style when it doesn't fit: holds
/// still, glides left until the whole string has passed, then snaps back and
/// repeats. Two copies of the text ride side by side so the wrap is seamless.
/// Text that fits is drawn as plain static `Text` — no timeline runs.
struct MarqueeText: View {
    let text: String
    let font: Font
    /// Gap between the end of the text and its repeat.
    var gap: CGFloat = 32
    /// Scroll speed in points per second.
    var speed: CGFloat = 28
    /// How long the text sits still at the start of every loop.
    var hold: TimeInterval = 1.0
    /// Where the text sits when it fits (scrolling text always runs from the
    /// leading edge). Centre it under centred artwork in the portrait card.
    var alignment: Alignment = .leading

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var epoch = Date()

    init(_ text: String, font: Font, alignment: Alignment = .leading) {
        self.text = text
        self.font = font
        self.alignment = alignment
    }

    private var overflows: Bool { containerWidth > 0 && textWidth > containerWidth + 0.5 }

    var body: some View {
        // The static text is always laid out: it gives the row its height,
        // measures the available width, and is what's shown when it fits.
        Text(text)
            .font(font)
            .lineLimit(1)
            .contentTransition(.opacity)
            .opacity(overflows ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: alignment)
            .background(measure { containerWidth = $0 })
            // Unconstrained copy in the background so it never affects layout.
            .background(
                Text(text).font(font).lineLimit(1).fixedSize()
                    .hidden()
                    .background(measure { textWidth = $0 })
            )
            .overlay(alignment: .leading) {
                if overflows { scrolling }
            }
            .clipped()
            .onChange(of: text) { _, _ in epoch = Date() }
    }

    private var scrolling: some View {
        let travel = textWidth + gap
        let scrollDuration = Double(travel / speed)
        let cycle = hold + scrollDuration
        return TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince(epoch).truncatingRemainder(dividingBy: cycle)
            let progress = max(0, t - hold) / scrollDuration
            let offset = -CGFloat(progress) * travel
            HStack(spacing: gap) {
                Text(text).font(font).lineLimit(1).fixedSize()
                Text(text).font(font).lineLimit(1).fixedSize()
            }
            .offset(x: offset)
            // Fade the trailing edge so text slides out rather than getting
            // chopped; the leading edge fades in only once it has moved.
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: offset < -1 ? 10 : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 14)
                }
            )
        }
        .frame(width: containerWidth, alignment: .leading)
    }

    private func measure(_ update: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { g in
            Color.clear
                .onAppear { update(g.size.width) }
                .onChange(of: g.size.width) { _, w in update(w) }
        }
    }
}
