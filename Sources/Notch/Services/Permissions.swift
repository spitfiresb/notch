import AppKit
import ApplicationServices

/// How a single macOS permission currently stands.
enum PermissionGrant: Equatable {
    case granted
    case denied
    case undetermined
    /// Can't be evaluated right now (e.g. Spotify isn't running).
    case unknown
}

/// One poll of every permission the notch cares about. Cheap to compute and
/// safe to call on a timer — nothing in here fires a system prompt.
struct PermissionsSnapshot: Equatable {
    var accessibility: PermissionGrant
    var automation: PermissionGrant
    var screenshots: PermissionGrant
    var spotifyRunning: Bool

    var allRequiredGranted: Bool { accessibility == .granted }
}

/// Thin helpers around the macOS permissions the notch needs, plus deep links
/// into the relevant System Settings panes for the onboarding flow.
enum Permissions {

    static func snapshot() -> PermissionsSnapshot {
        PermissionsSnapshot(
            accessibility: accessibilityTrusted ? .granted : .denied,
            automation: automationStatus(),
            screenshots: screenshotFolderStatus(),
            spotifyRunning: SpotifyBridge.isRunning)
    }

    // MARK: Accessibility

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    // MARK: Automation (Apple Events → Spotify)

    /// TCC's Apple-Events query API (AEDeterminePermissionToAppleEvents) is gone
    /// from current macOS, and merely *sending* an event fires the consent prompt
    /// while the state is undetermined. So: report .undetermined until the user
    /// has explicitly connected once, and only then poll by sending a harmless
    /// event — at that point TCC is decided and the send can't prompt again.
    private static let automationProbedKey = "didProbeSpotifyAutomation"

    static func automationStatus() -> PermissionGrant {
        guard SpotifyBridge.isRunning else { return .unknown }
        guard UserDefaults.standard.bool(forKey: automationProbedKey) else { return .undetermined }
        return spotifyControllable ? .granted : .denied
    }

    /// True once Spotify is running *and* an Apple Event to it succeeds (i.e. permission granted).
    static var spotifyControllable: Bool {
        guard SpotifyBridge.isRunning else { return false }
        var error: NSDictionary?
        _ = NSAppleScript(source: "tell application \"Spotify\" to return name")?.executeAndReturnError(&error)
        return error == nil
    }

    static func requestSpotifyAutomation() {
        // The send blocks until the user answers the consent dialog; only after
        // that is it safe for the snapshot poll to start sending events too.
        SpotifyBridge.triggerPermissionPrompt()
        UserDefaults.standard.set(true, forKey: automationProbedKey)
    }

    // MARK: Files & Folders (screenshot directory)

    /// TCC has no query API for file access, and merely reading the folder fires
    /// the consent prompt on first touch — so we only read after the user has
    /// explicitly asked once, and remember that we did.
    private static let probedKey = "didProbeScreenshotFolder"

    static func screenshotFolderStatus() -> PermissionGrant {
        guard UserDefaults.standard.bool(forKey: probedKey) else { return .undetermined }
        return probeScreenshotFolderAccess() ? .granted : .denied
    }

    /// Attempts to read the screenshots folder; fires the native consent prompt
    /// the first time.
    @discardableResult
    static func probeScreenshotFolderAccess() -> Bool {
        // The read blocks while the consent dialog is up; flag it probed only
        // afterwards so the snapshot poll doesn't also block on the dialog.
        let ok = (try? FileManager.default.contentsOfDirectory(atPath: ScreenshotWatcher.screenshotDirectory.path)) != nil
        UserDefaults.standard.set(true, forKey: probedKey)
        return ok
    }

    // MARK: System Settings deep links

    /// `anchor` is a `PermissionPrompt.rawValue` (e.g. `Privacy_Accessibility`).
    static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
