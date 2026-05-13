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
            .environmentObject(env.clipboard)
        let panel = NotchPanel(rootView: root)
        self.panel = panel
        panel.show()

        // Drive the panel's size/position from NotchState.
        env.notch.$size
            .removeDuplicates()
            .sink { [weak panel] size in panel?.apply(contentSize: size) }
            .store(in: &cancellables)

        installHoverWatcher()
        env.start()

        if !UserDefaults.standard.bool(forKey: "didCompleteOnboarding") {
            showOnboarding()
        }
    }

    /// Open / close the notch based on whether the cursor is over the panel's *current*
    /// frame. Polled (not SwiftUI `.onHover`, not event monitors) so it stays rock-stable
    /// while the panel resizes and regardless of which app is active.
    private func installHoverWatcher() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.evaluateHover()
        }
        RunLoop.main.add(hoverTimer!, forMode: .common)
    }

    private func evaluateHover() {
        guard let panel else { return }
        let notch = env.notch
        if panel.frame.contains(NSEvent.mouseLocation) {
            notch.cancelScheduledClose()
            if !notch.isOpen { notch.open() }
        } else if notch.isOpen {
            notch.scheduleClose(after: 0.25)
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
