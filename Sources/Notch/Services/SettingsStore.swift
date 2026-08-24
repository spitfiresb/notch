import Foundation
import Combine
import ServiceManagement

/// User-configurable feature toggles. Backed by `UserDefaults` for app-local
/// preferences and by the system `com.apple.screencapture` domain for settings
/// that have to bridge into macOS itself.
@MainActor
final class SettingsStore: ObservableObject {
    /// Copy each new screenshot to the system clipboard so it can be pasted immediately.
    @Published var copyScreenshotToClipboard: Bool {
        didSet { UserDefaults.standard.set(copyScreenshotToClipboard, forKey: Keys.copyScreenshot) }
    }

    /// Auto-route screenshots into `~/Pictures/Screenshots` instead of the Desktop,
    /// managed via the system `com.apple.screencapture.location` preference. Pictures
    /// isn't TCC-protected, so this needs no folder permission — unlike watching the
    /// Desktop. Flipping this off restores macOS's default Desktop location.
    @Published var routeScreenshotsToFolder: Bool {
        didSet { Self.applyScreenshotRouting(enabled: routeScreenshotsToFolder) }
    }

    /// Register the app as a login item so it comes back after restarts and
    /// shutdowns. Mirrors `SMAppService.mainApp` — the system is the source of
    /// truth, UserDefaults just remembers whether we've done the initial opt-in.
    @Published var launchAtLogin: Bool {
        didSet { Self.applyLaunchAtLogin(enabled: launchAtLogin) }
    }

    /// Show live Claude Code sessions in the notch. Installs hook entries into
    /// ~/.claude/settings.json (removed again when turned off).
    @Published var claudeSessionsEnabled: Bool {
        didSet { UserDefaults.standard.set(claudeSessionsEnabled, forKey: Keys.claudeSessions) }
    }

    private enum Keys {
        static let claudeSessions = "settings.claudeSessionsEnabled"
        static let copyScreenshot = "settings.copyScreenshotToClipboard"
        static let launchAtLoginSeeded = "settings.launchAtLogin.seeded"
    }

    /// The managed folder we point macOS at when routing is enabled.
    static var managedScreenshotURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Screenshots")
    }

    init() {
        let defaults = UserDefaults.standard
        // First launch: clipboard-copy preserves the prior always-on behavior.
        if defaults.object(forKey: Keys.copyScreenshot) == nil {
            defaults.set(true, forKey: Keys.copyScreenshot)
        }
        copyScreenshotToClipboard = defaults.bool(forKey: Keys.copyScreenshot)
        if defaults.object(forKey: Keys.claudeSessions) == nil {
            defaults.set(true, forKey: Keys.claudeSessions)
        }
        claudeSessionsEnabled = defaults.bool(forKey: Keys.claudeSessions)
        // Routing reflects the live system pref — the user (or this app) may have
        // already pointed `screencapture` somewhere; mirror reality, don't overwrite it.
        routeScreenshotsToFolder = Self.detectScreenshotRouting()
        // First launch: opt in to launch-at-login once so the app survives
        // restarts out of the box. After that, mirror the system's status so a
        // user who removed us in System Settings isn't silently re-added.
        if defaults.bool(forKey: Keys.launchAtLoginSeeded) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } else {
            defaults.set(true, forKey: Keys.launchAtLoginSeeded)
            launchAtLogin = true
            Self.applyLaunchAtLogin(enabled: true)
        }
    }

    private static func applyLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            notchLog("launch-at-login \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }

    /// True when `com.apple.screencapture.location` is already our managed path.
    private static func detectScreenshotRouting() -> Bool {
        guard let raw = CFPreferencesCopyAppValue("location" as CFString,
                                                  "com.apple.screencapture" as CFString) as? String
        else { return false }
        return (raw as NSString).expandingTildeInPath == managedScreenshotURL.path
    }

    private static func applyScreenshotRouting(enabled: Bool) {
        if enabled {
            try? FileManager.default.createDirectory(at: managedScreenshotURL,
                                                     withIntermediateDirectories: true)
            CFPreferencesSetAppValue("location" as CFString,
                                     managedScreenshotURL.path as CFString,
                                     "com.apple.screencapture" as CFString)
        } else {
            CFPreferencesSetAppValue("location" as CFString, nil,
                                     "com.apple.screencapture" as CFString)
        }
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
    }
}
