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

    /// Asymmetric: fade + slide in when *appearing*; on *disappearance*, a zero-duration
    /// opacity transition so the old layout vanishes immediately (no lingering ghost
    /// while the blob shrinks back). `.identity` was wrong here — it actually keeps the
    /// view visible for the full transition duration before snapping away.
    private static let contentTransition: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .offset(y: 6)),
        removal: .opacity.animation(.linear(duration: 0)))

    @ViewBuilder private var content: some View {
        if let toast = notch.toast {
            ScreenshotToastView(toast: toast)
                .padding(.horizontal, 14)
                .foregroundStyle(.white)
                .transition(Self.contentTransition)
        } else if notch.isOpen {
            VStack(spacing: 7) {
                tabBar
                tabContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 11)
            .foregroundStyle(.white)
            .transition(Self.contentTransition)
        } else {
            CollapsedPeek().transition(.identity)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(NotchState.Tab.allCases) { tab in
                Button { notch.open(tab: tab) } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 30, height: 19)
                        .background(notch.tab == tab ? Color.white.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .foregroundStyle(notch.tab == tab ? .white : .white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 19)
    }

    @ViewBuilder private var tabContent: some View {
        switch notch.tab {
        case .music:       MusicTabView()
        case .screenshots: ScreenshotTabView()
        case .settings:    SettingsTabView()
        }
    }
}

/// What's visible when the notch is collapsed — a hint of the current track.
private struct CollapsedPeek: View {
    @EnvironmentObject private var music: NowPlayingManager

    private var showing: Bool { music.info.isPlaying }

    var body: some View {
        HStack(spacing: 8) {
            artwork
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Spacer(minLength: 0)
            EqualizerBars()
                .frame(width: 15, height: 11)
                .opacity(0.9)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(showing ? 1 : 0)
    }

    @ViewBuilder private var artwork: some View {
        if let image = music.info.artwork {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Color.white.opacity(0.15)
        }
    }
}

/// Three little bars bobbing up and down.
struct EqualizerBars: View {
    @State private var animating = false
    private let heights: [CGFloat] = [0.45, 1.0, 0.65]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(.white)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: animating ? heights[i] : heights[(i + 1) % 3], anchor: .bottom)
                    .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(i) * 0.12),
                               value: animating)
            }
        }
        .onAppear { animating = true }
    }
}
