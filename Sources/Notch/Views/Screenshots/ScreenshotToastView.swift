import SwiftUI

/// Minimal "screenshot copied to clipboard" banner: the label wipes in left→right,
/// then a white ring sweeps 360° on its right and a checkmark strokes in. Nothing else.
struct ScreenshotToastView: View {
    let toast: ScreenshotToast

    /// Notch-expand settle time before anything in the banner starts moving.
    private static let lead = 0.34       // wait for the notch to finish expanding
    private static let perChar = 0.018

    var body: some View {
        HStack(spacing: 9) {
            CascadeText(text: toast.message, startDelay: Self.lead, perChar: Self.perChar)
                .font(.system(size: 12, weight: .semibold))
                .kerning(-0.1)
                .foregroundStyle(.white)
            CircleCheckmark(delay: Self.lead + Double(toast.message.count) * Self.perChar + 0.04)
                .frame(width: 18, height: 18)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(toast.url) }
    }
}

/// Text whose characters spring in one after another, left → right.
private struct CascadeText: View {
    let text: String
    var startDelay: Double = 0
    var perChar: Double = 0.02
    @State private var shown = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { idx, ch in
                Text(ch == " " ? "\u{00A0}" : String(ch))
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.5, anchor: .bottom)
                    .offset(y: shown ? 0 : 5)
                    .animation(.spring(response: 0.36, dampingFraction: 0.6)
                        .delay(startDelay + Double(idx) * perChar), value: shown)
            }
        }
        .onAppear { shown = true }
    }
}

/// A white stroked circle that draws itself around (a 360° sweep), then a checkmark
/// strokes in inside it. Runs once on appear.
struct CircleCheckmark: View {
    var delay: Double = 0
    @State private var ring: CGFloat = 0
    @State private var check: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: ring)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CheckmarkShape()
                .trim(from: 0, to: check)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .padding(4)
        }
        .onAppear {
            ring = 0; check = 0
            withAnimation(.easeInOut(duration: 0.4).delay(delay)) { ring = 1 }
            withAnimation(.easeOut(duration: 0.22).delay(delay + 0.34)) { check = 1 }
        }
    }
}

private struct CheckmarkShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.16, y: r.minY + r.height * 0.54))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.40, y: r.minY + r.height * 0.78))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.84, y: r.minY + r.height * 0.26))
        return p
    }
}
