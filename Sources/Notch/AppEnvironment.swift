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
        ScreenshotWatcher.disableSystemFloatingThumbnail()
        screenshots.onNewScreenshot = { [weak self] url in
            ScreenshotWatcher.copyToPasteboard(url)
            self?.notch.presentScreenshotToast(url: url)
        }
        screenshots.start()
    }
}

/// Transient "screenshot copied" banner shown in the notch.
struct ScreenshotToast: Equatable {
    let url: URL
    let message: String
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
    @Published var toast: ScreenshotToast?

    /// While set & in the future, the hover-watcher won't auto-collapse.
    private(set) var pinnedUntil: Date?
    var isPinnedOpen: Bool { (pinnedUntil ?? .distantPast) > Date() }

    private var closeWork: DispatchWorkItem?

    func open(tab newTab: Tab? = nil) {
        closeWork?.cancel(); closeWork = nil
        pinnedUntil = nil
        toast = nil
        if let newTab { tab = newTab }
        isOpen = true
    }

    func close() {
        closeWork?.cancel(); closeWork = nil
        pinnedUntil = nil
        toast = nil
        isOpen = false
    }

    func dismissToast() { toast = nil }

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

    /// Pop the notch open with a "screenshot copied" banner; auto-collapses after a beat.
    func presentScreenshotToast(url: URL) {
        closeWork?.cancel(); closeWork = nil
        toast = ScreenshotToast(url: url, message: "Screenshot copied to clipboard")
        tab = .screenshots          // what's revealed if the banner is dismissed early
        isOpen = true
        pinnedUntil = Date().addingTimeInterval(2.25)
        scheduleClose(after: 2.35)
    }
}
