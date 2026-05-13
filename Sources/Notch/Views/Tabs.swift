import SwiftUI
import ImageIO

// MARK: - Music

struct MusicTabView: View {
    @EnvironmentObject private var env: AppEnvironment
    private var info: NowPlayingInfo { env.music.info }

    var body: some View {
        HStack(spacing: 14) {
            artwork
                .frame(width: 86, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.1)))

            VStack(alignment: .leading, spacing: 3) {
                Text(info.hasContent ? info.title : "Nothing playing")
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(info.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                if !info.album.isEmpty {
                    Text(info.album).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 24) {
                    control("backward.fill", size: 15) { env.music.previous() }
                    control(info.isPlaying ? "pause.fill" : "play.fill", size: 20) { env.music.togglePlayPause() }
                    control("forward.fill", size: 15) { env.music.next() }
                    Spacer()
                    if !info.source.isEmpty {
                        Text(info.source).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium)).contentShape(Rectangle())
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
                Image(systemName: "music.note").font(.title2).foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

// MARK: - Screenshots

struct ScreenshotTabView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        if env.screenshots.shots.isEmpty {
            EmptyTab(symbol: "camera.viewfinder", text: "Screenshots will show up here")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(env.screenshots.shots, id: \.self) { url in
                        ScreenshotThumb(url: url)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct ScreenshotThumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.07)
            }
        }
        .frame(width: 158, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
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
        .task(id: url) { image = await Self.thumbnail(for: url) }
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

// MARK: - Clipboard

struct ClipboardTabView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        if env.clipboard.items.isEmpty {
            EmptyTab(symbol: "doc.on.clipboard", text: "Copied text & images land here")
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(env.clipboard.items) { item in
                        Button { env.clipboard.copy(item) } label: { row(for: item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 2)
            }
        }
    }

    private func row(for item: ClipItem) -> some View {
        HStack(spacing: 10) {
            switch item.kind {
            case .text(let s):
                Image(systemName: "text.alignleft").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                Text(s.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
            case .image(let img):
                Image(systemName: "photo").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Settings

struct SettingsTabView: View {
    @State private var refresh = false   // toggled to re-read live permission state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow("Accessibility", ok: Permissions.accessibilityTrusted) { Permissions.openAccessibilitySettings() }
            statusRow("Control Spotify", ok: Permissions.spotifyControllable) { Permissions.openAutomationSettings() }
            statusRow("Screenshot folder", ok: Permissions.probeScreenshotFolderAccess()) { Permissions.openFilesAndFoldersSettings() }
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                Button("Re-run setup…") { AppDelegate.shared?.showOnboarding() }
                Button("Refresh") { refresh.toggle() }
                Spacer()
                Button("Quit Notch") { NSApp.terminate(nil) }
                    .foregroundStyle(.red.opacity(0.9))
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
        }
        .id(refresh)
    }

    private func statusRow(_ title: String, ok: Bool, openSettings: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? .green : .yellow)
            Text(title).font(.system(size: 13))
            Spacer()
            if !ok {
                Button("Fix", action: openSettings).buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

// MARK: - Shared

private struct EmptyTab: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.white.opacity(0.35))
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
