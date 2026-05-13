import SwiftUI
import ImageIO

// MARK: - Music

struct MusicTabView: View {
    @EnvironmentObject private var music: NowPlayingManager
    private var info: NowPlayingInfo { music.info }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                artwork
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.12)))

                VStack(alignment: .leading, spacing: 1) {
                    Text(info.hasContent ? info.title : "Nothing playing")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                    if info.hasContent {
                        Text(info.artist)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                control("backward.fill", size: 13) { music.previous() }
                Spacer().frame(width: 26)
                control(info.isPlaying ? "pause.fill" : "play.fill", size: 17) { music.togglePlayPause() }
                Spacer().frame(width: 26)
                control("forward.fill", size: 13) { music.next() }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: size + 12, height: size + 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!info.hasContent)
        .opacity(info.hasContent ? 1 : 0.3)
    }

    @ViewBuilder private var artwork: some View {
        if let image = info.artwork {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "music.note").font(.system(size: 15)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

// MARK: - Screenshots

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

enum Haptics {
    private static var lastTick = Date.distantPast

    /// macOS exposes no intensity knob, so a "strong" tap = two `.levelChange` pulses
    /// stacked close together — that's about as hard as the trackpad will hit.
    static func tick() {
        let now = Date()
        guard now.timeIntervalSince(lastTick) > 0.06 else { return }   // de-machine-gun
        lastTick = now
        let perf = NSHapticFeedbackManager.defaultPerformer
        perf.perform(.levelChange, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.024) {
            perf.perform(.levelChange, performanceTime: .now)
        }
    }
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

/// Minimal "screenshot copied to clipboard" banner: the label wipes in left→right,
/// then a white ring sweeps 360° on its right and a checkmark strokes in. Nothing else.
struct ScreenshotToastView: View {
    let toast: ScreenshotToast

    /// Notch-expand settle time before anything in the banner starts moving.
    private static let lead = 0.22
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

/// Helpers for screenshot thumbnails / timestamps.
enum ScreenshotImage {
    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func relativeTime(_ date: Date?) -> String {
        guard let date else { return "" }
        if -date.timeIntervalSinceNow < 45 { return "just now" }
        return relFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func thumbnail(for url: URL, maxPixel: CGFloat = 400) async -> NSImage? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { cont.resume(returning: nil); return }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: NSImage(cgImage: cg, size: .zero))
            }
        }
    }
}

// MARK: - Settings

struct SettingsTabView: View {
    @State private var refresh = false   // toggled to re-read live permission state

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            statusRow("Accessibility", ok: Permissions.accessibilityTrusted) { Permissions.openAccessibilitySettings() }
            statusRow("Control Spotify", ok: Permissions.spotifyControllable) { Permissions.openAutomationSettings() }
            statusRow("Screenshot folder", ok: Permissions.probeScreenshotFolderAccess()) { Permissions.openFilesAndFoldersSettings() }
            Spacer(minLength: 2)
            HStack(spacing: 12) {
                Button("Setup…") { AppDelegate.shared?.showOnboarding() }
                Button("Refresh") { refresh.toggle() }
                Spacer(minLength: 0)
                Button("Quit") { NSApp.terminate(nil) }.foregroundStyle(.red.opacity(0.9))
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(refresh)
    }

    private func statusRow(_ title: String, ok: Bool, openSettings: @escaping () -> Void) -> some View {
        HStack(spacing: 7) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(ok ? .green : .yellow)
            Text(title)
            Spacer(minLength: 0)
            if !ok {
                Button("Fix", action: openSettings)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - Shared

private struct EmptyTab: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.white.opacity(0.3))
            Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
