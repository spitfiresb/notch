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
    private var overlayTimer: Timer?
    /// Timestamp of the most recent trackpad-driven swipe end. The space-change
    /// notification arrives around the same time; if we just animated via the
    /// trackpad handler we don't want to fire the public-API slide on top of it.
    private var trackpadSwipeEndedAt: Date?
    /// True while the user has 3+ fingers down on the trackpad. Used to suppress
    /// the space-change and dock-overlay handlers so they don't fight the live
    /// drag (the system commits the space mid-swipe, before the user lifts).
    private var trackpadGestureActive = false
    /// True once the pre-emptive hide animation has fired for the current
    /// gesture. We only kick it off once per gesture, not on every frame.
    private var trackpadHideAnimationStarted = false
    /// On gesture end, if the panel is currently occluded by WindowServer (the
    /// full-screen-Space gesture path) we defer the settle animation until
    /// occlusion lifts — otherwise the easeOut runs invisibly and the user
    /// sees the notch "pop" into its base position on the new Space.
    private var pendingOcclusionSettle = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        let root = NotchRootView()
            .environmentObject(env.notch)
            .environmentObject(env.music)
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
                guard let panel else { return }
                if active {
                    self?.env.notch.close()
                    panel.orderOut(nil)
                } else {
                    self?.slidePanelDown()
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
    /// (the small pill when collapsed, the whole panel when open). Polled so it's stable
    /// regardless of which app is active or whether the panel ignores mouse events.
    private func installHoverWatcher() {
        let t = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in self?.evaluateHover() }
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
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
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

    /// Bring the panel back on screen after a hot-corner overlay closes. Starts the
    /// window just above the screen edge and animates its frame down so the notch
    /// pill drops in instead of popping in place.
    private func slidePanelDown() {
        guard let panel, let screen = ScreenMetrics.screen else { return }
        let sf = screen.frame
        let size = ScreenMetrics.expandedSize
        let x = (sf.minX + sf.maxX) / 2 - size.width / 2
        let startFrame = NSRect(x: x, y: sf.maxY, width: size.width, height: size.height)
        let endFrame = NSRect(x: x, y: sf.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(startFrame, display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrame(endFrame, display: true)
        }
    }

    /// Animate the panel up off the screen edge. Used when the system is starting
    /// some screen-wide transition (currently: a Spaces swipe) so the pill gets out
    /// of the way before sliding back down.
    private func slidePanelUp(then completion: (() -> Void)? = nil) {
        guard let panel, let screen = ScreenMetrics.screen else {
            completion?()
            return
        }
        let sf = screen.frame
        let curr = panel.frame
        let upFrame = NSRect(x: curr.origin.x, y: sf.maxY,
                             width: curr.width, height: curr.height)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(upFrame, display: true)
        }, completionHandler: completion)
    }

    /// Three-finger swipe between Spaces (or any other space change). `activeSpaceDidChange`
    /// fires as the new space slides in, so we slide the notch up out of the way and
    /// drop it back down once the swipe has settled.
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

        // If a trackpad swipe ended in an occluded state, the slide-down was
        // deferred. The new space is now active and (after a small grace
        // period for any residual occlusion flickering to settle) the user
        // will actually see the easeOut.
        if pendingOcclusionSettle {
            pendingOcclusionSettle = false
            notchLog("[notch.sw] handleSpaceChange firing pending settle")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.animateSettleDown()
            }
        }

        // Don't fight the Mission Control / Launchpad handler.
        guard !env.notch.isSystemOverlayActive else { return }
        // Trackpad monitor owns the animation while a gesture is in flight,
        // and for a short window after, so the public-API slide doesn't pile on.
        if trackpadGestureActive { return }
        if let t = trackpadSwipeEndedAt, Date().timeIntervalSince(t) < 0.8 { return }
        env.notch.close()
        slidePanelUp { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self?.slidePanelDown()
            }
        }
    }

    /// Real-time three-finger swipe tracking via MultitouchSupport. While the
    /// user is dragging across the trackpad, position the panel proportionally
    /// to swipe magnitude; when fingers lift, animate the panel back to rest.
    /// Log occlusion changes for diagnostics, but don't act on them — the
    /// system flips occlusion several times per full-screen swipe sequence,
    /// so triggering settle here would race with the next re-occlusion and
    /// make the slide-down "sometimes work." We fire the settle on
    /// `activeSpaceDidChange` instead (in handleSpaceChange).
    private func installPanelVisibilityWatcher() {
        guard let panel else { return }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel,
            queue: .main
        ) { [weak panel] _ in
            guard let panel else { return }
            notchLog("[notch.pn] occlusion visible=\(panel.occlusionState.contains(.visible)) raw=\(panel.occlusionState.rawValue)")
        }
    }

    private func installTrackpadMonitor() {
        let monitor = TrackpadGestureMonitor.shared
        monitor.onUpdate = { [weak self] dx, dy in
            self?.trackpadGestureActive = true
            self?.handleTrackpadSwipe(dx: dx, dy: dy)
        }
        monitor.onEnd = { [weak self] in
            self?.trackpadGestureActive = false
            self?.handleTrackpadSwipeEnd()
        }
        monitor.start()
    }

    private func handleTrackpadSwipe(dx: CGFloat, dy: CGFloat) {
        guard !env.notch.isSystemOverlayActive else { return }

        let absDx = abs(dx)
        let absDy = abs(dy)
        // Only react to horizontal-dominant swipes — vertical 3-finger gestures
        // are Mission Control, handled separately by the overlay watcher.
        guard absDx > 0.05, absDx > absDy * 1.3 else { return }

        // New gesture motion cancels any in-flight deferred settle.
        pendingOcclusionSettle = false

        // 40% of trackpad travel = fully hidden. Anything more is clamped. We
        // set the offset live (no animation wrapper) so SwiftUI snaps to each
        // value — this gives a finger-proportional drag while WindowServer is
        // still compositing us. Once the system occludes the panel (only
        // inside full-screen Spaces, ~270 ms after fingers land), no public or
        // private API lets us render through; live updates just won't show.
        let progress = min(1.0, absDx / 0.40)
        env.notch.swipeOffset = progress
    }

    private func handleTrackpadSwipeEnd() {
        trackpadSwipeEndedAt = Date()
        trackpadHideAnimationStarted = false
        let isOccluded = !(panel?.occlusionState.contains(.visible) ?? true)
        notchLog("[notch.sw] END off=\(String(format: "%.2f", Double(env.notch.swipeOffset))) occluded=\(isOccluded)")
        if isOccluded {
            // Wait for occlusion to lift (handled by the panel-visibility
            // watcher) before animating. Belt-and-suspenders timeout too.
            pendingOcclusionSettle = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.pendingOcclusionSettle else { return }
                self.pendingOcclusionSettle = false
                self.animateSettleDown()
            }
        } else {
            animateSettleDown()
        }
    }

    private func animateSettleDown() {
        notchLog("[notch.sw] animateSettleDown from \(String(format: "%.2f", Double(env.notch.swipeOffset)))")
        withAnimation(.easeOut(duration: 0.32)) {
            env.notch.swipeOffset = 0
        }
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
        SettingsWindowController.present(settings: env.settings)
    }
}
