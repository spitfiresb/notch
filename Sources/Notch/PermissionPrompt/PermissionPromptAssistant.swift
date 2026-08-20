import AppKit
import Foundation

/// Routes a "Grant" click to the right flow for the permission's current state:
/// fire the native consent prompt when the system still can, or open the exact
/// System Settings pane with a floating overlay showing what to do there.
/// The overlay tracks the Settings window and auto-dismisses once granted.
@MainActor
final class PermissionPromptAssistant {
    static let shared = PermissionPromptAssistant()

    private var overlayController: PermissionOverlayWindowController?
    private var trackingTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var activePrompt: PermissionPrompt?
    private var didPresentCurrentOverlay = false

    init() {}

    /// Entry point that picks the right path for the prompt and current grant state.
    /// - Accessibility: opens System Settings and shows the drag-to-add overlay.
    /// - Automation (undetermined): fires the native consent prompt — no overlay.
    /// - Automation (denied): opens System Settings and shows the flip-the-toggle overlay.
    /// - Files & Folders: same undetermined/denied split as Automation.
    func request(_ prompt: PermissionPrompt) {
        switch prompt {
        case .accessibility:
            guard Permissions.accessibilityTrusted == false else { dismiss(); return }
            present(prompt: .accessibility, variant: .dragToList)

        case .automation:
            switch Permissions.automationStatus() {
            case .granted, .unknown:
                dismiss()
            case .undetermined:
                dismiss()
                refocusAfterNativePrompt { Permissions.requestSpotifyAutomation() }
            case .denied:
                present(prompt: .automation, variant: .toggleInList)
            }

        case .filesAndFolders:
            switch Permissions.screenshotFolderStatus() {
            case .granted, .unknown:
                dismiss()
            case .undetermined:
                dismiss()
                refocusAfterNativePrompt { Permissions.probeScreenshotFolderAccess() }
            case .denied:
                present(prompt: .filesAndFolders, variant: .toggleInList)
            }
        }
    }

    /// The system permission alert (owned by tccd) takes focus while it's
    /// visible. When it dismisses, macOS runs its own app-switch and prefers a
    /// regular-policy app over our accessory app — so whatever was previously
    /// frontmost wins unless we re-activate *after* that switch settles.
    private func refocusAfterNativePrompt(_ fire: @escaping () -> Void) {
        let windowToRefocus = NSApp.keyWindow ?? NSApp.mainWindow
        Task { @MainActor in
            fire()  // blocks until the user answers the consent dialog
            try? await Task.sleep(nanoseconds: 250_000_000)
            // Re-key our window only if Notch is still the active app. If the
            // consent dialog handed focus elsewhere (System Settings, say),
            // stealing it back on every click is worse than staying behind.
            guard NSApp.isActive else { return }
            if let window = windowToRefocus, window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func present(
        prompt: PermissionPrompt,
        variant: PermissionOverlayVariant,
        hostApp: PermissionPromptHostApp = .current()
    ) {
        dismiss()
        activePrompt = prompt
        didPresentCurrentOverlay = false
        overlayController = PermissionOverlayWindowController(
            hostApp: hostApp,
            prompt: prompt,
            variant: variant
        ) { [weak self] in
            self?.dismiss()
        }
        prompt.openSettings()
        startTracking()
    }

    func dismiss() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        overlayController?.close()
        overlayController = nil
        activePrompt = nil
        didPresentCurrentOverlay = false
    }

    private func startTracking() {
        trackingTimer?.invalidate()
        // Follow the Settings window at 0.15s, but probe the grant state only
        // every ~1s — the automation / folder probes are real work (an Apple
        // Event round-trip, a directory read), unlike the position lookup.
        var tick = 0
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            tick += 1
            let checkGrant = tick % 7 == 0
            Task { @MainActor in
                self?.refreshPosition()
                if checkGrant { self?.dismissIfGranted() }
            }
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                PermissionPromptAssistant.shared.refreshPosition()
            }
        }
        refreshPosition()
    }

    private func refreshPosition() {
        guard let snapshot = SettingsWindowLocator.frontmostWindow() else {
            overlayController?.hide()
            return
        }
        if didPresentCurrentOverlay {
            overlayController?.updatePosition(with: snapshot.frame, visibleFrame: snapshot.visibleFrame)
            return
        }

        overlayController?.present(
            settingsFrame: snapshot.frame,
            visibleFrame: snapshot.visibleFrame
        )
        didPresentCurrentOverlay = true
    }

    private func dismissIfGranted() {
        guard let activePrompt else { return }
        let granted: Bool
        switch activePrompt {
        case .accessibility:
            granted = Permissions.accessibilityTrusted
        case .automation:
            granted = Permissions.automationStatus() == .granted
        case .filesAndFolders:
            granted = Permissions.screenshotFolderStatus() == .granted
        }
        if granted { dismiss() }
    }
}
