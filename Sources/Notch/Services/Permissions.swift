import AppKit
import ApplicationServices

/// Thin helpers around the macOS permissions the notch needs, plus deep links
/// into the relevant System Settings panes for the onboarding flow.
enum Permissions {

    // MARK: Accessibility

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "grant Accessibility access" prompt (only the first time).
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Automation (Apple Events → Spotify)

    /// True once Spotify is running *and* an Apple Event to it succeeds (i.e. permission granted).
    static var spotifyControllable: Bool {
        guard SpotifyBridge.isRunning else { return false }
        var error: NSDictionary?
        _ = NSAppleScript(source: "tell application \"Spotify\" to return name")?.executeAndReturnError(&error)
        return error == nil
    }

    static func requestSpotifyAutomation() { SpotifyBridge.triggerPermissionPrompt() }

    // MARK: Files & Folders (screenshot directory)

    @discardableResult
    static func probeScreenshotFolderAccess() -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: ScreenshotWatcher.screenshotDirectory.path)) != nil
    }

    // MARK: System Settings deep links

    static func openAccessibilitySettings() { open("Privacy_Accessibility") }
    static func openAutomationSettings()     { open("Privacy_Automation") }
    static func openFilesAndFoldersSettings() { open("Privacy_FilesAndFolders") }

    private static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
