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
            // Directional drop shadow — a blurred dark capsule positioned just under
            // the blob's bottom edge. The all-around `.shadow()` we used to apply on
            // the blob bled into the 8 pt cornerInset strips on the sides, painting
            // them faintly gray; this confines the shadow to below the notch where it
            // actually wants to be.
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.36))
                .frame(width: max(0, blobSize.width - 40), height: 10)
                .blur(radius: 10)
                .offset(y: blobSize.height - 4)

            blobShape
                .fill(.black)
                // Clip the stroke to the blob so the 1 pt line doesn't render its
                // outer half in the cornerInset strips.
                .overlay(
                    blobShape.stroke(Color.white.opacity(0.06), lineWidth: 1)
                        .clipShape(blobShape)
                )
                .frame(width: blobSize.width, height: blobSize.height)

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

/// What's visible when the notch is collapsed — album art on the left, dancing bars
/// on the right. Padding/anchoring match the music tab's bars exactly so the cross-fade
/// between "peek" and "tab" lands the bars on the same pixel — they look like one
/// element staying put while the rest of the tab fades in around them.
private struct CollapsedPeek: View {
    @EnvironmentObject private var music: NowPlayingManager

    /// Show whenever there's *any* track loaded; we just freeze the bars when paused
    /// so the user can still see what's playing at a glance.
    private var showing: Bool { music.info.hasContent }

    private static let trackFade: Animation = .easeInOut(duration: 0.34)

    var body: some View {
        HStack(spacing: 0) {
            artwork
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.white.opacity(0.12)))
                .opacity(music.displayArt != nil ? 1 : 0)
            Spacer(minLength: 0)
            DancingBars(color: music.displayAccent,
                        isPlaying: music.info.isPlaying)
                .frame(width: 20, height: 14)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(showing ? 1 : 0)
        .animation(Self.trackFade, value: music.displayKey)
        .animation(Self.trackFade, value: music.displayAccent)
    }

    @ViewBuilder private var artwork: some View {
        Group {
            if let image = music.displayArt {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.clear
            }
        }
        .id(music.displayKey)
        .transition(.opacity)
    }
}

/// Six bars whose heights track either real audio (via `AudioMeter`'s six band levels,
/// low frequencies first) or, when no tap signal is available, a continuous sine wiggle.
/// When paused, the bars freeze at a low resting height.
struct DancingBars: View {
    var color: Color = .white
    var isPlaying: Bool = true

    @EnvironmentObject private var meter: AudioMeter

    /// Low resting height when paused / silent — short, equal capsules.
    private static let restHeight: CGFloat = 0.22
    private static let barWidth: CGFloat = 1.8
    private static let spacing: CGFloat = 1.3
    private static let count = AudioMeter.bandCount

    var body: some View {
        if !isPlaying {
            HStack(alignment: .center, spacing: Self.spacing) {
                ForEach(0..<Self.count, id: \.self) { _ in
                    bar(height: Self.restHeight)
                }
            }
        } else if meter.isRunning {
            // Real audio — re-renders every time the meter publishes new levels.
            HStack(alignment: .center, spacing: Self.spacing) {
                ForEach(0..<Self.count, id: \.self) { i in
                    bar(height: meter.bars[i])
                }
            }
            .animation(.easeOut(duration: 0.06), value: meter.bars)
        } else {
            // Fallback: synthesized wiggle so playing-without-permission still feels alive.
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: Self.spacing) {
                    ForEach(0..<Self.count, id: \.self) { i in
                        bar(height: scale(t, phase: Double(i) * 1.1))
                    }
                }
            }
        }
    }

    private func bar(height: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(color)
            .frame(width: Self.barWidth)
            .frame(maxHeight: .infinity)
            .scaleEffect(y: max(Self.restHeight, height), anchor: .center)
    }

    /// Two summed sines at different frequencies → an organic, non-repeating wiggle.
    private func scale(_ t: Double, phase: Double) -> CGFloat {
        let a = sin(t * 5.2 + phase)        * 0.5 + 0.5
        let b = sin(t * 9.7 + phase * 2.1)  * 0.5 + 0.5
        return CGFloat(0.22 + (a * 0.6 + b * 0.4) * 0.78)
    }
}
