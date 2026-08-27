import SwiftUI

/// Tracks whether the strip is actively being scrolled — a plain class so mutating it
/// doesn't churn SwiftUI re-renders; thumbnails read it to mute their hover effects mid-scroll.
final class ScrollActivity { var isScrolling = false }

struct ScreenshotTabView: View {
    @EnvironmentObject private var screenshots: ScreenshotWatcher

    private static let thumbWidth: CGFloat = 104
    private static let spacing: CGFloat = 8
    private static let step = thumbWidth + spacing
    private static let space = "screenshotScroll"

    @State private var activity = ScrollActivity()
    @State private var lastSlot = Int.min
    @State private var settleWork: DispatchWorkItem?

    var body: some View {
        if screenshots.shots.isEmpty {
            EmptyTab(symbol: "camera.viewfinder", text: "Screenshots show up here")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.spacing) {
                    ForEach(screenshots.shots, id: \.self) { url in
                        ScreenshotThumb(url: url, activity: activity)
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: ScrollOffsetKey.self,
                                           value: g.frame(in: .named(Self.space)).minX)
                })
            }
            .coordinateSpace(name: Self.space)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onPreferenceChange(ScrollOffsetKey.self) { minX in
                handleScroll(offset: minX)
            }
        }
    }

    private func handleScroll(offset minX: CGFloat) {
        // Mark "scrolling" and auto-clear shortly after movement settles.
        activity.isScrolling = true
        settleWork?.cancel()
        let work = DispatchWorkItem { activity.isScrolling = false }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)

        // One haptic per thumbnail crossed — boundary at the half-step, so small jitter
        // around a boundary won't flip the slot.
        let slot = Int((-minX / Self.step).rounded())
        if slot != lastSlot {
            if lastSlot != Int.min { Haptics.tick() }
            lastSlot = slot
        }
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ScreenshotThumb: View {
    let url: URL
    let activity: ScrollActivity
    @State private var image: NSImage?
    @State private var date: Date?
    @State private var hovering = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.07)
            }
        }
        .frame(width: 104, height: 64)
        .overlay(alignment: .bottom) {
            if hovering {
                Text(relativeTime(date))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 5)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(hovering ? 0.26 : 0.12)))
        .scaleEffect(hovering ? 0.95 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { h in
            guard !activity.isScrolling else { return }   // don't fight the scroll
            withAnimation(.easeOut(duration: 0.16)) { hovering = h }
            if h { Haptics.tick() }
        }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copy") { ScreenshotWatcher.copyToPasteboard(url) }
        }
        .task(id: url) {
            image = await ScreenshotImage.thumbnail(for: url)
            date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    private func relativeTime(_ date: Date?) -> String { ScreenshotImage.relativeTime(date) }
}
