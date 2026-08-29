import SwiftUI
import Combine

/// Shared, observable app state injected into every SwiftUI view.
@MainActor
final class AppEnvironment: ObservableObject {
    let notch = NotchState()
    let music = NowPlayingManager()
    let spotify = SpotifyLibrary()
    let screenshots = ScreenshotWatcher()
    let audioMeter = AudioMeter()
    let settings = SettingsStore()
    let claude = ClaudeSessionStore()

    private var cancellables = Set<AnyCancellable>()
    /// Pending delayed audio-meter teardown after playback pauses.
    private var meterStopWork: DispatchWorkItem?

    func start() {
        music.start()
        spotify.start()
        // Feed track changes into the Spotify library so the like/playlist
        // lookup always describes what's actually playing.
        music.$info
            .map(\.spotifyTrackID)
            .removeDuplicates()
            .sink { [weak self] id in self?.spotify.trackChanged(id) }
            .store(in: &cancellables)
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
        // Claude Code sessions: install hooks once on first launch (toggle in
        // Settings removes them), then tail the event spool.
        if settings.claudeSessionsEnabled && !ClaudeHooks.isInstalled { ClaudeHooks.install() }
        settings.$claudeSessionsEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] on in self?.claude.setHooksEnabled(on) }
            .store(in: &cancellables)
        claude.onAttention = { [weak self] s in
            notchLog("claude-sessions: attention \(s.projectName) \(s.state) \(s.attention ?? s.lastReply ?? "")")
            let kind: SessionToast.Kind
            switch s.state {
            case .done:    kind = .complete
            case .failed:  kind = .failed
            case .waiting: kind = s.waitingReason == .question ? .question : .permission
            default:       return
            }
            self?.notch.presentSessionToast(SessionToast(session: s, kind: kind))
        }
        // A needs-you toast is moot once the user has answered (or the
        // session is gone): fold it away early.
        claude.$sessions
            .sink { [weak self] sessions in
                guard let self, case .session(let t) = self.notch.toast, t.kind.needsYou else { return }
                if let live = sessions.first(where: { $0.id == t.session.id }), live.needsAttention { return }
                self.notch.dismissToast()
            }
            .store(in: &cancellables)
        claude.start()
    }
}

/// Transient "screenshot copied" banner shown in the notch.
struct ScreenshotToast: Equatable {
    let url: URL
    let message: String
}

/// Transient Clawd banner for a session event.
struct SessionToast: Equatable {
    enum Kind: Equatable {
        case complete, permission, question, failed
        /// Blocked on the user — stays up longer, dismissed early once answered.
        var needsYou: Bool { self == .permission || self == .question }
        /// How long the notch stays open.
        var duration: TimeInterval {
            switch self {
            case .complete:   2.7
            case .permission: 5.6
            case .question:   5.6
            case .failed:     4.6
            }
        }
    }
    let session: ClaudeSession
    let kind: Kind
    /// Long folder names get clipped so the banner still fits `toastSize`.
    var message: String {
        let name = session.projectName
        let shown = name.count > 14 ? String(name.prefix(13)) + "…" : name
        switch kind {
        case .complete:   return "\(shown) session complete"
        case .permission: return "\(shown) needs permission"
        case .question:   return "\(shown) has a question"
        case .failed:     return "\(shown) session failed"
        }
    }
}

enum NotchToast: Equatable {
    case screenshot(ScreenshotToast)
    case session(SessionToast)
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
    @Published var tab: Tab = .music {
        didSet { if tab != .music { musicPanelExpanded = false } }
    }
    /// Claude sessions panel unfolded beneath the current tab — opened by
    /// hovering the spinner in the panel's bottom-right corner.
    @Published var sessionsPanelExpanded = false {
        didSet { if sessionsPanelExpanded { musicPanelExpanded = false } }
    }
    /// Blob size while open. The sessions panel is only as tall as its rows
    /// (capped at the music-panel height, the window's fixed size).
    func openBlobSize(sessionRows: Int) -> CGSize {
        guard isOpen else { return ScreenMetrics.collapsedSize(for: dock) }
        let expanded = ScreenMetrics.expandedSize(for: dock)
        // The side strip has no room for the playlist / sessions fold-outs.
        guard dock == .top else { return expanded }
        let biggest = ScreenMetrics.windowSize(for: dock)
        if tab == .music && musicPanelExpanded { return biggest }
        guard sessionsPanelExpanded else { return expanded }
        let h = expanded.height + SessionsPanel.height(rows: sessionRows) + 10
        return CGSize(width: expanded.width, height: min(h, biggest.height))
    }
    @Published var toast: NotchToast?
    /// Music tab's taller state — the "Saved in" playlist panel unfolded
    /// beneath the transport controls.
    @Published var musicPanelExpanded = false {
        didSet { if musicPanelExpanded { sessionsPanelExpanded = false } }
    }

    /// Which screen edge the notch is docked to. Set by dragging the blob
    /// (NotchDragController), persisted across launches.
    @Published var dock: NotchDock = NotchDock.stored {
        didSet { dock.store() }
    }
    /// True from the moment a drag tears the blob off its edge until it has
    /// landed on its new one. The blob hides (the drag overlay draws the
    /// droplet and landing ghost instead) and the hover watcher stands down.
    @Published var isDockDragging = false

    /// `true` while Mission Control / App Exposé / Launchpad / Show Desktop is on
    /// screen. The panel is fully hidden then so it doesn't cover the system overlay.
    @Published var isSystemOverlayActive: Bool = false

    /// While set & in the future, the hover-watcher won't auto-collapse.
    private(set) var pinnedUntil: Date?
    var isPinnedOpen: Bool { (pinnedUntil ?? .distantPast) > Date() }

    private var closeWork: DispatchWorkItem?
    private var tabRevertWork: DispatchWorkItem?

    /// How long a non-default tab survives after the notch collapses before we
    /// snap back to the music tab.
    private static let tabRevertDelay: TimeInterval = 30

    func open(tab newTab: Tab? = nil) {
        closeWork?.cancel(); closeWork = nil
        tabRevertWork?.cancel(); tabRevertWork = nil
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
        musicPanelExpanded = false
        sessionsPanelExpanded = false
        scheduleTabRevert()
    }

    /// The tab you were on sticks after the notch collapses — re-hovering within
    /// `tabRevertDelay` brings you back to it. Past that, revert to music.
    private func scheduleTabRevert() {
        tabRevertWork?.cancel(); tabRevertWork = nil
        guard tab != .music else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.tabRevertWork = nil
            if !self.isOpen { self.tab = .music }
        }
        tabRevertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tabRevertDelay, execute: work)
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
        toast = .screenshot(ScreenshotToast(url: url, message: "Screenshot copied to clipboard"))
        tab = .screenshots          // what's revealed if the banner is dismissed early
        isOpen = true
        pinnedUntil = Date().addingTimeInterval(2.25)
        scheduleClose(after: 2.35)
    }

    /// Pop the notch open with a Clawd banner for a session event.
    func presentSessionToast(_ t: SessionToast) {
        closeWork?.cancel(); closeWork = nil
        toast = .session(t)
        sessionsPanelExpanded = false
        isOpen = true
        pinnedUntil = Date().addingTimeInterval(t.kind.duration - 0.1)
        scheduleClose(after: t.kind.duration)
    }
}
