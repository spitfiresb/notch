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

struct ScreenshotTabView: View {
    @EnvironmentObject private var screenshots: ScreenshotWatcher

    var body: some View {
        if screenshots.shots.isEmpty {
            EmptyTab(symbol: "camera.viewfinder", text: "Screenshots show up here")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(screenshots.shots, id: \.self) { url in
                        ScreenshotThumb(url: url)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ScreenshotThumb: View {
    let url: URL
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
                Text(Self.relativeTime(date))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 5)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(hovering ? 0.28 : 0.12)))
        .scaleEffect(hovering ? 0.93 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { h in
            withAnimation(.easeOut(duration: 0.14)) { hovering = h }
            if h { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copy") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([url as NSURL])
            }
        }
        .task(id: url) {
            image = await Self.thumbnail(for: url)
            date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func relativeTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let secondsAgo = -date.timeIntervalSinceNow
        if secondsAgo < 45 { return "just now" }
        return relFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func thumbnail(for url: URL, maxPixel: CGFloat = 360) async -> NSImage? {
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
