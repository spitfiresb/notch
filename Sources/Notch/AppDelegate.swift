import AppKit
import SwiftUI
import Combine
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    private let env = AppEnvironment()
    private var panel: NotchPanel?
    private var onboarding: OnboardingWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var hoverTimer: Timer?
    private var hoverGlobalMonitor: Any?
    private var hoverLocalMonitor: Any?
    private var overlayTimer: Timer?
    /// Pending "drop the window after the retract animation" — cancelled if the
    /// overlay closes again before it fires.
    private var overlayHideWork: DispatchWorkItem?
    /// True while the user has 3+ fingers down on the trackpad. Used to suppress
    /// the dock-overlay handler — a Spaces swipe briefly produces a Dock-owned
    /// window that trips the Mission Control heuristic, and reacting to it would
    /// yank the panel off screen mid-gesture.
    private var trackpadGestureActive = false

    func applicationWillTerminate(_ notification: Notification) {
        SpaceAttacher.detach()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        let root = NotchRootView()
            .environmentObject(env.notch)
            .environmentObject(env.music)
            .environmentObject(env.spotify)
            .environmentObject(env.screenshots)
            .environmentObject(env.audioMeter)
            .environmentObject(env.settings)
        let panel = NotchPanel(rootView: root)
        self.panel = panel
        panel.show()

        panel.onHorizontalSwipe = { [weak self] dir in self?.cycleTab(by: dir) }

        // Let the menu bar under the collapsed pill stay clickable; capture clicks when open.
        env.notch.$isOpen
            .removeDuplicates()
            .sink { [weak panel] open in panel?.ignoresMouseEvents = !open }
            .store(in: &cancellables)

        // Hot-corner / Mission Control: when Dock.app takes the screen, pull the panel
        // off-screen so it can't cover the windows the system is trying to reveal.
        // Drop the first value so we don't animate on app launch (initial state is false).
        env.notch.$isSystemOverlayActive
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self, weak panel] active in
                guard let self, let panel else { return }
                self.overlayHideWork?.cancel()
                self.overlayHideWork = nil
                if active {
                    self.env.notch.close()
                    // The root view retracts the blob up past the top edge; drop
                    // the window only after that plays out. (This is only visible
                    // because the overlay space sits at absolute level 400 —
                    // at level 0 WindowServer blanks us during the Mission
                    // Control build-in and the retract read as a glitchy
                    // disappear-reappear.)
                    let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
                    self.overlayHideWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
                } else {
                    // Content is still retracted (offset above the top edge), so
                    // showing the window is invisible; the state flip then springs
                    // the blob back down purely in SwiftUI — the window frame
                    // never animates, which is what made the old return janky.
                    panel.reposition()
                    panel.orderFrontRegardless()
                    SpaceAttacher.attachToAllSpaces(panel)
                }
            }
            .store(in: &cancellables)

        installHoverWatcher()
        installSystemOverlayWatcher()
        installSpaceChangeWatcher()
        installTrackpadMonitor()
        installPanelVisibilityWatcher()
        env.start()

        if !UserDefaults.standard.bool(forKey: "didCompleteOnboarding") {
            showOnboarding()
        } else {
            // Brief "hello" — open the notch on launch so it's discoverable without hovering.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.env.notch.presentLaunchGreeting()
            }
        }
    }

    /// Open / close the notch based on whether the cursor is over the *visible* blob
    /// (the small pill when collapsed, the whole panel when open). Driven by mouse-move
    /// events (global + local monitors, so it works regardless of which app is active)
    /// instead of a fast poll — a stationary cursor costs nothing. A slow safety timer
    /// covers the cases where the blob changes under a stationary cursor (toast expiry,
    /// open/close animations).
    private func installHoverWatcher() {
        // Monitor handlers are delivered on the main thread but the closures are
        // typed nonisolated — assumeIsolated instead of Task so the local monitor
        // can return its event synchronously.
        hoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateHover() }
        }
        hoverLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.evaluateHover() }
            return event
        }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.evaluateHover() }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    private func evaluateHover() {
        guard let panel else { return }
        let notch = env.notch
        if notch.isSystemOverlayActive { return }
        let wf = panel.frame
        let blobRect: NSRect = notch.isOpen
            ? wf
            : NSRect(x: wf.midX - ScreenMetrics.notchSize.width / 2,
                     y: wf.maxY - ScreenMetrics.notchSize.height,
                     width: ScreenMetrics.notchSize.width,
                     height: ScreenMetrics.notchSize.height)

        if blobRect.contains(NSEvent.mouseLocation) {
            notch.cancelScheduledClose()
            if !notch.isOpen {
                notch.open()
            } else if notch.toast != nil && !notch.isPinnedOpen {
                notch.dismissToast()   // banner's time is up — reveal the tabs underneath
            }
        } else if notch.isOpen && !notch.isPinnedOpen {
            notch.close()
        }
    }

    /// Mission Control, App Exposé, and Launchpad each draw a window owned by the
    /// Dock process that's far taller than the normal Dock strip. Poll for one and
    /// mirror that into `NotchState.isSystemOverlayActive` so the panel can step
    /// aside. (NSWorkspace's frontmost-app notifications don't fire for these
    /// overlays — the user's previous app stays the "active" application for menu
    /// bar / keyboard purposes — so direct observation is the only reliable signal.)
    private func installSystemOverlayWatcher() {
        // 0.4 s is deliberately slow — each evaluation is a CGWindowListCopyWindowInfo
        // IPC round-trip to WindowServer, and the occlusion-state watcher below fires
        // an extra evaluation the instant an overlay actually starts, so this poll is
        // mostly a recovery path for the overlay *closing*.
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.evaluateSystemOverlay()
        }
        RunLoop.main.add(t, forMode: .common)
        overlayTimer = t
    }

    private func evaluateSystemOverlay() {
        // Don't fight a live trackpad drag — the spaces transition can briefly
        // produce a Dock-owned window that looks like Mission Control to our
        // heuristic, and orderOut'ing mid-gesture would yank the panel.
        if trackpadGestureActive { return }
        let active = AppDelegate.dockOverlayOnScreen()
        if env.notch.isSystemOverlayActive != active {
            notchLog("[notch.ov] isSystemOverlayActive -> \(active)")
            env.notch.isSystemOverlayActive = active
        }
    }


    /// A Space change doesn't move the notch — it stays pinned in place. All we
    /// do is re-attach it to the (possibly brand-new) set of Spaces.
    private func installSpaceChangeWatcher() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSpaceChange()
        }
    }

    private func handleSpaceChange() {
        // Re-attach to all spaces — entering full-screen creates a brand-new
        // Space, and a window only pinned to the previous set won't be on it.
        if let panel { SpaceAttacher.attachToAllSpaces(panel) }
    }

    /// WindowServer occludes the panel during full-screen-Space transitions and
    /// the instant a hot-corner overlay (Mission Control / App Exposé) starts.
    /// That occlusion event fires ~120ms before the 0.15s overlay poll would
    /// notice, so we also re-evaluate the overlay right here — it's what lets the
    /// window be dropped during the compositor blink instead of popping back in
    /// over Mission Control for a beat.
    private func installPanelVisibilityWatcher() {
        guard let panel else { return }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            guard let panel else { return }
            notchLog("[notch.pn] occlusion visible=\(panel.occlusionState.contains(.visible)) raw=\(panel.occlusionState.rawValue)")
            self?.evaluateSystemOverlay()
        }
    }

    /// The monitor no longer drives any hide animation — we only track whether a
    /// gesture is in flight so `evaluateSystemOverlay` stands down while the
    /// system shuffles windows around mid-swipe.
    private func installTrackpadMonitor() {
        let monitor = TrackpadGestureMonitor.shared
        monitor.onUpdate = { [weak self] _, _ in self?.trackpadGestureActive = true }
        monitor.onEnd = { [weak self] in self?.trackpadGestureActive = false }
        monitor.start()
    }

    /// `true` when Mission Control / App Exposé / Launchpad is on screen. Detected
    /// by spotting a Dock-owned window that is either a screen-spanning overlay
    /// (the dim layer Mission Control / Launchpad draw across everything) *or* the
    /// thin "spaces strip" anchored to the top edge in Mission Control's steady
    /// state. Requiring `layer > 0` skips the desktop wallpaper (also Dock-owned,
    /// but at a deeply negative layer); the size checks skip the regular Dock strip.
    private static func dockOverlayOnScreen() -> Bool {
        let opts: CGWindowListOption = [.optionOnScreenOnly]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]],
              let screen = ScreenMetrics.screen else { return false }
        let sf = screen.frame
        return list.contains { info in
            guard let owner = info[kCGWindowOwnerName as String] as? String, owner == "Dock",
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer > 0 else { return false }
            let y = bounds["Y"] ?? 0
            let w = bounds["Width"] ?? 0
            let h = bounds["Height"] ?? 0
            guard w > sf.width * 0.5 else { return false }
            // Big overlay (MC dim, Launchpad full screen, App Exposé background).
            if h > sf.height * 0.4 { return true }
            // Mission Control's top thumbnail strip: wide, short, hugs the top edge.
            if h > 80 && y < 100 { return true }
            return false
        }
    }

    /// Move forward (+1) or back (-1) through the tab list, ignoring swipes when the
    /// notch isn't open or a toast is showing. Stops at the ends (doesn't wrap).
    private func cycleTab(by dir: Int) {
        let notch = env.notch
        guard notch.isOpen, notch.toast == nil else { return }
        let tabs = NotchState.Tab.allCases
        guard let i = tabs.firstIndex(of: notch.tab) else { return }
        let new = i + dir
        guard new >= 0, new < tabs.count else { return }
        notch.tab = tabs[new]
        Haptics.tick()
    }

    func showOnboarding() {
        let controller = OnboardingWindowController { [weak self] in
            UserDefaults.standard.set(true, forKey: "didCompleteOnboarding")
            self?.onboarding = nil
        }
        onboarding = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettingsWindow() {
        SettingsWindowController.present(settings: env.settings, spotify: env.spotify)
    }
}
