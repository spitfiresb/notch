import SwiftUI
import Combine

/// Shared, observable app state injected into every SwiftUI view.
@MainActor
final class AppEnvironment: ObservableObject {
    let notch = NotchState()
    let music = NowPlayingManager()
    let screenshots = ScreenshotWatcher()

    func start() {
        music.start()
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
        case music, screenshots, settings
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .music: "music.note"
            case .screenshots: "camera.viewfinder"
            case .settings: "gearshape"
            }
        }
    }

    @Published var isOpen = false
    @Published var tab: Tab = .music

    /// While set & in the future, the hover-watcher won't auto-collapse (used by `flash`).
    private(set) var pinnedUntil: Date?
    var isPinnedOpen: Bool { (pinnedUntil ?? .distantPast) > Date() }

    private var closeWork: DispatchWorkItem?

    func open(tab newTab: Tab? = nil) {
        closeWork?.cancel(); closeWork = nil
        if let newTab { tab = newTab }
        isOpen = true
    }

    func close() {
        closeWork?.cancel(); closeWork = nil
        pinnedUntil = nil
        isOpen = false
    }

    func cancelScheduledClose() { closeWork?.cancel(); closeWork = nil }

    func scheduleClose(after delay: TimeInterval) {
        guard isOpen, closeWork == nil else { return }   // already counting down — leave it
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            if self.isPinnedOpen {
                self.scheduleClose(after: max(0.1, (self.pinnedUntil ?? Date()).timeIntervalSinceNow + 0.05))
            } else {
                self.close()
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Pop open on a tab and keep it open for a few seconds (Dynamic-Island style).
    func flash(tab: Tab) {
        open(tab: tab)
        pinnedUntil = Date().addingTimeInterval(5)
        scheduleClose(after: 5.1)
    }
}
