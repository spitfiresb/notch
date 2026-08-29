import AppKit
import SwiftUI
import XCTest
@testable import Notch

/// Offscreen render harness. Not assertions about pixels — it draws the notch
/// in each dock and state to PNGs under `.build/renders/` so the layout can be
/// eyeballed (and diffed) without a screen or a cursor.
///
///     swift test && open .build/renders
@MainActor
final class RenderTests: XCTestCase {
    private var outDir: URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dir = cwd.appendingPathComponent(".build/renders")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor private struct Env {
        let notch = NotchState()
        let music = NowPlayingManager()
        let spotify = SpotifyLibrary()
        let screenshots = ScreenshotWatcher()
        let audioMeter = AudioMeter()
        let settings = SettingsStore()
        let claude = ClaudeSessionStore()

        func inject<V: View>(_ v: V) -> some View {
            v.environmentObject(notch)
                .environmentObject(music)
                .environmentObject(spotify)
                .environmentObject(screenshots)
                .environmentObject(audioMeter)
                .environmentObject(settings)
                .environmentObject(claude)
        }
    }

    private static func fakeArt() -> NSImage {
        let img = NSImage(size: NSSize(width: 64, height: 64))
        img.lockFocus()
        NSGradient(colors: [NSColor(red: 0.95, green: 0.45, blue: 0.25, alpha: 1),
                            NSColor(red: 0.35, green: 0.15, blue: 0.55, alpha: 1)])!
            .draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), angle: 45)
        img.unlockFocus()
        return img
    }

    private func seed(_ env: Env, podcast: Bool) {
        var info = NowPlayingInfo()
        info.title = podcast ? "The Anthony Bourdain Special Episode" : "Say It Ain't So"
        info.artist = podcast ? "The Watch" : "Weezer"
        info.isPlaying = true
        info.duration = podcast ? 3610 : 255
        info.elapsed = podcast ? 812 : 61
        info.elapsedAt = Date()
        info.isPodcast = podcast
        info.playbackRate = podcast ? 1.5 : 1
        env.music.debugSeed(info: info, art: Self.fakeArt(),
                            accent: Color(red: 0.95, green: 0.5, blue: 0.3))
    }

    /// Render `view` at `size`, optionally cropping the result to `crop`
    /// (in the view's points, top-left origin).
    private func write(_ view: some View, size: CGSize, crop: CGRect? = nil, name: String) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard var cg = renderer.cgImage else { return XCTFail("no image for \(name)") }
        if let crop {
            let px = CGRect(x: crop.minX * 2, y: crop.minY * 2, width: crop.width * 2, height: crop.height * 2)
            guard let c = cg.cropping(to: px) else { return XCTFail("crop \(name)") }
            cg = c
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("png \(name)") }
        try? png.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    /// The root view lays the blob out in screen coordinates and the panel
    /// window is only a viewport onto it, so the harness does the same: render
    /// the whole screen and crop to the docked window's frame.
    private var screenSize: CGSize { ScreenMetrics.screen?.frame.size ?? CGSize(width: 1728, height: 1117) }
    private func windowCrop(for dock: NotchDock) -> CGRect {
        guard let s = ScreenMetrics.screen else { return .zero }
        let f = ScreenMetrics.windowFrame(for: dock)
        return CGRect(x: f.minX - s.frame.minX, y: s.frame.maxY - f.maxY, width: f.width, height: f.height)
    }

    /// The root view on a desktop-grey ground so the black blob and its shadow read.
    private func root(_ env: Env) -> some View {
        env.inject(NotchRootView())
            .background(Color(red: 0.42, green: 0.45, blue: 0.52))
    }
    private func panel(_ env: Env, dock: NotchDock, open: Bool) -> some View {
        env.notch.dock = dock
        env.notch.isOpen = open
        return root(env)
    }
    /// Write the docked window's view of the root.
    private func writeDocked(_ env: Env, dock: NotchDock, name: String) {
        write(root(env), size: screenSize, crop: windowCrop(for: dock), name: name)
    }

    func testDockStates() {
        for dock in NotchDock.allCases {
            for podcast in [false, true] {
                let env = Env()
                seed(env, podcast: podcast)
                let kind = podcast ? "podcast" : "song"
                if !podcast {
                    env.notch.dock = dock; env.notch.isOpen = false
                    writeDocked(env, dock: dock, name: "\(dock)-collapsed")
                }
                env.notch.dock = dock; env.notch.isOpen = true
                writeDocked(env, dock: dock, name: "\(dock)-open-\(kind)")
            }
        }
        // Screenshots tab, empty state, side dock.
        let env = Env()
        seed(env, podcast: false)
        env.notch.tab = .screenshots
        env.notch.dock = .left; env.notch.isOpen = true
        writeDocked(env, dock: .left, name: "left-open-screenshots")
    }

    func testSideToast() {
        let env = Env()
        seed(env, podcast: false)
        let session = ClaudeSession(id: "abc", cwd: "/Users/me/Desktop/notch",
                                    lastEventAt: Date(), startedAt: Date())
        for dock in [NotchDock.top, .right] {
            env.notch.dock = dock
            env.notch.toast = .session(SessionToast(session: session, kind: .complete))
            env.notch.isOpen = true
            writeDocked(env, dock: dock, name: "\(dock)-toast")
        }
    }

    func testDrag() {
        // Mid-drag, the whole screen: the droplet floats where the cursor is
        // and every edge shows its landing ghost with the nearest one lit.
        let sz = screenSize
        for (target, cursor) in [(NotchDock.top, CGPoint(x: sz.width * 0.55, y: 140)),
                                 (.left, CGPoint(x: 160, y: sz.height * 0.5)),
                                 (.right, CGPoint(x: sz.width - 200, y: sz.height * 0.45))] {
            let env = Env()
            seed(env, podcast: false)
            env.notch.dock = .top
            env.notch.isDockDragging = true
            env.notch.dragTarget = target
            env.notch.dragCursor = cursor
            write(root(env), size: sz, name: "drag-\(target)")
        }
        // Landed on the right: the same view, docked, full screen.
        let env = Env()
        seed(env, podcast: false)
        env.notch.dock = .right
        write(root(env), size: sz, name: "drag-right-landed")
    }
}
