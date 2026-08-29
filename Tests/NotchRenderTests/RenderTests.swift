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

    private func write(_ view: some View, size: CGSize, name: String) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return XCTFail("no image for \(name)") }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("png \(name)") }
        try? png.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    /// The panel, on a desktop-grey ground so the black blob and its shadow read.
    private func panel(_ env: Env, dock: NotchDock, open: Bool) -> some View {
        env.notch.dock = dock
        env.notch.isOpen = open
        return env.inject(NotchRootView())
            .background(Color(red: 0.42, green: 0.45, blue: 0.52))
    }

    func testDockStates() {
        for dock in NotchDock.allCases {
            for podcast in [false, true] {
                let env = Env()
                seed(env, podcast: podcast)
                let size = ScreenMetrics.windowSize(for: dock)
                let kind = podcast ? "podcast" : "song"
                if !podcast {
                    write(panel(env, dock: dock, open: false), size: size, name: "\(dock)-collapsed")
                }
                write(panel(env, dock: dock, open: true), size: size, name: "\(dock)-open-\(kind)")
            }
        }
        // Screenshots tab, empty state, portrait.
        let env = Env()
        seed(env, podcast: false)
        env.notch.tab = .screenshots
        write(panel(env, dock: .left, open: true), size: ScreenMetrics.windowSize(for: .left),
              name: "left-open-screenshots")
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
            write(env.inject(NotchRootView()).background(Color(red: 0.42, green: 0.45, blue: 0.52)),
                  size: ScreenMetrics.windowSize(for: dock), name: "\(dock)-toast")
        }
    }

    func testDragOverlay() {
        // A scaled-down screen: the ghost hugs the target edge, the droplet
        // floats where the cursor is.
        let screen = CGSize(width: 900, height: 560)
        for (dock, cursor) in [(NotchDock.top, CGPoint(x: 520, y: 140)),
                               (.left, CGPoint(x: 160, y: 300)),
                               (.right, CGPoint(x: 760, y: 260))] {
            let model = DockDragModel()
            model.screenSize = screen
            model.target = dock
            model.cursor = cursor
            model.phase = .dragging
            write(DockDragOverlayView(model: model)
                    .background(Color(red: 0.42, green: 0.45, blue: 0.52)),
                  size: screen, name: "overlay-\(dock)")
        }
        let model = DockDragModel()
        model.screenSize = screen
        model.target = .right
        model.phase = .settling
        write(DockDragOverlayView(model: model)
                .background(Color(red: 0.42, green: 0.45, blue: 0.52)),
              size: screen, name: "overlay-right-settled")
    }
}
