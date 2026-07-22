import SwiftUI
import Combine

/// Shared, observable app state injected into every SwiftUI view.
@MainActor
final class AppEnvironment: ObservableObject {
    let notch = NotchState()
    let music = NowPlayingManager()
    let screenshots = ScreenshotWatcher()
    let audioMeter = AudioMeter()
    let settings = SettingsStore()

    private var cancellables = Set<AnyCancellable>()
    /// Pending delayed audio-meter teardown after playback pauses.
    private var meterStopWork: DispatchWorkItem?

    func start() {
        music.start()
        // Run the system-audio tap only while something is actually playing —
        // the tap + realtime IO thread + 60 Hz UI publish are the app's main
        // idle CPU/battery cost, and the bars freeze when paused anyway. The
        // 2 s debounce on the stop side keeps track-skips and brief pauses
        // from churning the CoreAudio device setup.
        music.$info
            .map(\.isPlaying)
            .removeDuplicates()
            .sink { [weak self] playing in
                guard let self else { return }
                self.meterStopWork?.cancel(); self.meterStopWork = nil
                if playing {
                    self.audioMeter.start()
                } else {
                    let work = DispatchWorkItem { [weak self] in self?.audioMeter.stop() }
                    self.meterStopWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
                }
            }
            .store(in: &cancellables)
        ScreenshotWatcher.disableSystemFloatingThumbnail()
        screenshots.onNewScreenshot = { [weak self] url in
            guard let self else { return }
            if self.settings.copyScreenshotToClipboard {
                ScreenshotWatcher.copyToPasteboard(url)
            }
            self.notch.presentScreenshotToast(url: url)
        }
        // Re-point the filesystem watcher whenever the user flips auto-routing,
        // so the screenshot strip reflects the new folder without an app restart.
        // Drop the initial value so this fires only on user-driven changes.
        settings.$routeScreenshotsToFolder
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.screenshots.rebindToCurrentDirectory() }
            .store(in: &cancellables)
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
        case music, screenshots
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .music: "music.note"
            case .screenshots: "camera.viewfinder"
            }
        }
    }

    @Published var isOpen = false
    @Published var tab: Tab = .music
    @Published var toast: ScreenshotToast?

    /// `true` while Mission Control / App Exposé / Launchpad / Show Desktop is on
    /// screen. The panel is fully hidden then so it doesn't cover the system overlay.
    @Published var isSystemOverlayActive: Bool = false

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

    /// Open the notch briefly on app launch so it's visible without a hover, then
    /// auto-collapse. Pinned so the hover-watcher doesn't slam it shut immediately.
    func presentLaunchGreeting(duration: TimeInterval = 1.8) {
        closeWork?.cancel(); closeWork = nil
        toast = nil
        tab = .music
        isOpen = true
        pinnedUntil = Date().addingTimeInterval(duration)
        scheduleClose(after: duration + 0.1)
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
