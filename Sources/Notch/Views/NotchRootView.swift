import SwiftUI

/// The black blob: a tiny pill when idle, an expanding panel with tabs when open.
/// The view always fills the hosting window — the *window* is what changes size
/// (driven by `NotchState.size` from `AppDelegate`); this view just paints the
/// blob and swaps its contents.
struct NotchRootView: View {
    @EnvironmentObject private var notch: NotchState

    private var anim: Animation { .spring(response: 0.30, dampingFraction: 0.86) }
    private var collapsedRadius: CGFloat { min(10, ScreenMetrics.notchSize.height / 2) }

    /// Black left untouched at the top so it still reads as "below the notch".
    private let topInset: CGFloat = 12

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(.black)
            shape.stroke(Color.white.opacity(0.06), lineWidth: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(anim, value: notch.isOpen)
        .animation(anim, value: notch.tab)
        // Hover open/close is driven by AppDelegate's cursor watcher (not `.onHover`).
    }

    private var shape: NotchShape {
        NotchShape(cornerInset: 8, bottomRadius: notch.isOpen ? 20 : collapsedRadius)
    }

    @ViewBuilder private var content: some View {
        if notch.isOpen {
            VStack(spacing: 7) {
                tabBar
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.top, topInset)
            .padding(.bottom, 11)
            .foregroundStyle(.white)
            .transition(.opacity)
        } else {
            CollapsedPeek()
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

    var body: some View {
        HStack(spacing: 8) {
            artwork
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(music.info.hasContent ? 1 : 0)
            Spacer(minLength: 0)
            EqualizerBars()
                .frame(width: 15, height: 11)
                .opacity(music.info.hasContent && music.info.isPlaying ? 0.9 : 0)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
