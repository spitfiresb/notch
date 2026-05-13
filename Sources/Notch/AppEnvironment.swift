import SwiftUI
import Combine

/// Shared, observable app state injected into every SwiftUI view.
@MainActor
final class AppEnvironment: ObservableObject {
    let notch = NotchState()
    let music = NowPlayingManager()
    let screenshots = ScreenshotWatcher()
    let clipboard = ClipboardWatcher()

    func start() {
        music.start()
        clipboard.start()
        screenshots.onNewScreenshot = { [weak self] _ in
            self?.notch.flash(tab: .screenshots)
        }
        screenshots.start()
    }
}

/// Open / closed state of the notch panel plus which tab is showing.
@MainActor
final class NotchState: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case music, screenshots, clipboard, settings
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .music: "music.note"
            case .screenshots: "camera.viewfinder"
            case .clipboard: "doc.on.clipboard"
            case .settings: "gearshape"
            }
        }
    }

    @Published var isOpen = false
    @Published var tab: Tab = .music
    @Published var size: CGSize

    let collapsedSize = ScreenMetrics.notchSize
    let expandedSize = CGSize(width: 580, height: 300)

    private var closeWork: DispatchWorkItem?

    init() { size = ScreenMetrics.notchSize }

    func open(tab newTab: Tab? = nil) {
        closeWork?.cancel(); closeWork = nil
        if let newTab { tab = newTab }
        isOpen = true
        size = expandedSize
    }

    func close() {
        closeWork?.cancel(); closeWork = nil
        isOpen = false
        size = collapsedSize
    }

    func cancelScheduledClose() { closeWork?.cancel(); closeWork = nil }

    func scheduleClose(after delay: TimeInterval) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Pop open on a tab and auto-collapse shortly after (Dynamic-Island style).
    func flash(tab: Tab) {
        open(tab: tab)
        scheduleClose(after: 5)
    }
}
