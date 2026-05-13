import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    private let env = AppEnvironment()
    private var panel: NotchPanel?
    private var onboarding: OnboardingWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var hoverTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        let root = NotchRootView()
            .environmentObject(env.notch)
            .environmentObject(env.music)
            .environmentObject(env.screenshots)
        let panel = NotchPanel(rootView: root)
        self.panel = panel
        panel.show()

        // Let the menu bar under the collapsed pill stay clickable; capture clicks when open.
        env.notch.$isOpen
            .removeDuplicates()
            .sink { [weak panel] open in panel?.ignoresMouseEvents = !open }
            .store(in: &cancellables)

        installHoverWatcher()
        env.start()

        if !UserDefaults.standard.bool(forKey: "didCompleteOnboarding") {
            showOnboarding()
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
        let wf = panel.frame
        let blobRect: NSRect = notch.isOpen
            ? wf
            : NSRect(x: wf.midX - ScreenMetrics.notchSize.width / 2,
                     y: wf.maxY - ScreenMetrics.notchSize.height,
                     width: ScreenMetrics.notchSize.width,
                     height: ScreenMetrics.notchSize.height)

        if blobRect.contains(NSEvent.mouseLocation) {
            notch.cancelScheduledClose()
            if !notch.isOpen { notch.open() }
        } else if notch.isOpen && !notch.isPinnedOpen {
            notch.close()
        }
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
}
