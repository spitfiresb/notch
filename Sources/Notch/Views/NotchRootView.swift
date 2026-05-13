import SwiftUI

/// The black blob: a tiny pill when idle, an expanding panel with tabs on hover
/// (or when something — like a new screenshot — wants attention).
struct NotchRootView: View {
    @EnvironmentObject private var env: AppEnvironment
    private var notch: NotchState { env.notch }

    private var anim: Animation { .spring(response: 0.34, dampingFraction: 0.82) }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(cornerInset: 8, bottomRadius: notch.isOpen ? 22 : min(10, ScreenMetrics.notchSize.height / 2))
                .fill(.black)
                .overlay(
                    NotchShape(cornerInset: 8, bottomRadius: notch.isOpen ? 22 : min(10, ScreenMetrics.notchSize.height / 2))
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(notch.isOpen ? 0.35 : 0), radius: 18, y: 8)

            content
        }
        .frame(width: notch.size.width, height: notch.size.height, alignment: .top)
        .animation(anim, value: notch.isOpen)
        .animation(anim, value: notch.size)
        .onHover { hovering in
            if hovering {
                notch.cancelScheduledClose()
                if !notch.isOpen { notch.open() }
            } else if notch.isOpen {
                notch.scheduleClose(after: 0.35)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if notch.isOpen {
            VStack(spacing: 8) {
                tabBar
                Divider().overlay(.white.opacity(0.12))
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(14)
            .padding(.top, max(0, ScreenMetrics.notchSize.height - 14))
            .foregroundStyle(.white)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        } else {
            CollapsedPeek()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(NotchState.Tab.allCases) { tab in
                Button { withAnimation(anim) { notch.open(tab: tab) } } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 34, height: 26)
                        .background(notch.tab == tab ? Color.white.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch notch.tab {
        case .music:       MusicTabView()
        case .screenshots: ScreenshotTabView()
        case .clipboard:   ClipboardTabView()
        case .settings:    SettingsTabView()
        }
    }
}

/// What's visible when the notch is collapsed — a hint of the current track.
private struct CollapsedPeek: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        HStack(spacing: 8) {
            artwork
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(env.music.info.hasContent ? 1 : 0)
            Spacer(minLength: 0)
            EqualizerBars()
                .frame(width: 15, height: 11)
                .opacity(env.music.info.hasContent && env.music.info.isPlaying ? 0.9 : 0)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, max(0, (ScreenMetrics.notchSize.height - 18) / 2))
        .padding(.bottom, max(0, (ScreenMetrics.notchSize.height - 18) / 2))
    }

    @ViewBuilder private var artwork: some View {
        if let image = env.music.info.artwork {
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
