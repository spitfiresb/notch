import SwiftUI

/// The black blob: a tiny pill when idle, an expanding panel with tabs when open.
/// The hosting window is a fixed size (`ScreenMetrics.expandedSize`); this view paints
/// a blob that grows/shrinks within it, so open/close is one smooth SwiftUI animation.
struct NotchRootView: View {
    @EnvironmentObject private var notch: NotchState

    // Open is a touch slower than close so the content has time to register on the
    // eye; close feels right at 0.22s.
    private static let openAnim: Animation = .easeOut(duration: 0.32)
    private static let closeAnim: Animation = .easeOut(duration: 0.22)
    private var transitionAnim: Animation { notch.isOpen ? Self.openAnim : Self.closeAnim }

    private var blobSize: CGSize {
        if notch.toast != nil { return ScreenMetrics.toastSize }
        return notch.isOpen ? ScreenMetrics.expandedSize : ScreenMetrics.notchSize
    }
    private var bottomRadius: CGFloat {
        if notch.toast != nil { return 16 }
        return notch.isOpen ? 20 : min(10, ScreenMetrics.notchSize.height / 2)
    }

    private var blobShape: NotchShape { NotchShape(cornerInset: 8, bottomRadius: bottomRadius) }

    var body: some View {
        ZStack(alignment: .top) {
            blobShape
                .fill(.black)
                .overlay(blobShape.stroke(Color.white.opacity(0.06), lineWidth: 1))
                .frame(width: blobSize.width, height: blobSize.height)
                .shadow(color: .black.opacity(0.28), radius: 11, y: 4)

            content
                .frame(width: blobSize.width, height: blobSize.height)
                .clipShape(blobShape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(transitionAnim, value: notch.isOpen)
        .animation(Self.openAnim, value: notch.tab)
        .animation(transitionAnim, value: notch.toast)
        // Hover open/close is driven by AppDelegate's cursor watcher.
    }

    /// Peek and tab content are stacked & always present (just opacity-toggled) so they
    /// can share the *animated* `.frame(blobSize)` of the parent — the layout grows /
    /// shrinks with the blob, so right-edge elements (dancing bars) never escape the
    /// black silhouette during the open/close sweep.
    @ViewBuilder private var content: some View {
        ZStack {
            CollapsedPeek()
                .opacity(notch.isOpen || notch.toast != nil ? 0 : 1)

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .foregroundStyle(.white)
                .opacity(notch.isOpen && notch.toast == nil ? 1 : 0)

            if let toast = notch.toast {
                ScreenshotToastView(toast: toast)
                    .padding(.horizontal, 14)
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch notch.tab {
        case .music:       MusicTabView()
        case .screenshots: ScreenshotTabView()
        case .settings:    SettingsTabView()
        }
    }
}

/// What's visible when the notch is collapsed — just the dancing bars on the right.
/// Padding/anchoring match the music tab's bars exactly so the cross-fade between
/// "peek" and "tab" lands the bars on the same pixel — they look like one element
/// staying put while the rest of the tab fades in around them.
private struct CollapsedPeek: View {
    @EnvironmentObject private var music: NowPlayingManager

    private var showing: Bool { music.info.isPlaying }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            DancingBars(color: music.info.accentColor ?? .white)
                .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(showing ? 1 : 0)
    }
}

/// Three bars whose heights wiggle independently every frame — driven by
/// `TimelineView(.animation)` so it's continuous, not a stepped wave. Tinted with
/// the album-art accent.
struct DancingBars: View {
    var color: Color = .white

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                bar(height: scale(t, phase: 0.0))
                bar(height: scale(t, phase: 1.7))
                bar(height: scale(t, phase: 3.4))
            }
        }
    }

    private func bar(height: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(color)
            .frame(width: 2.5)
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
