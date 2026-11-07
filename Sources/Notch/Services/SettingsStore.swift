import Foundation
import Combine
import ServiceManagement

/// User-configurable feature toggles. Backed by `UserDefaults` for app-local
/// preferences and by the system `com.apple.screencapture` domain for settings
/// that have to bridge into macOS itself.
@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    /// Copy each new screenshot to the system clipboard so it can be pasted immediately.
    @Published var copyScreenshotToClipboard: Bool {
        didSet { defaults.set(copyScreenshotToClipboard, forKey: Keys.copyScreenshot) }
    }

    /// Auto-route screenshots into `~/Pictures/Screenshots` instead of the Desktop,
    /// managed via the system `com.apple.screencapture.location` preference. Pictures
    /// isn't TCC-protected, so this needs no folder permission — unlike watching the
    /// Desktop. Flipping this off restores the user's previous location.
    @Published var routeScreenshotsToFolder: Bool {
        didSet {
            guard routeScreenshotsToFolder != oldValue else { return }
            do {
                try ScreenshotRouting.current.setEnabled(routeScreenshotsToFolder)
                screenshotRoutingError = nil
            } catch {
                screenshotRoutingError = "Could not change the screenshot folder. Check that the folder is writable."
            }
            routeScreenshotsToFolder = Self.detectScreenshotRouting()
        }
    }

    @Published private(set) var screenshotRoutingError: String?
    @Published private(set) var loginItemError: String?

    /// Register the app as a login item so it comes back after restarts and
    /// shutdowns. Mirrors `SMAppService.mainApp` — the system is the source of
    /// truth. Registration only happens after an explicit toggle.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                loginItemError = SMAppService.mainApp.status == .requiresApproval
                    ? "Allow Notch in System Settings → General → Login Items." : nil
            } catch {
                loginItemError = "Could not update launch at login. Install Notch in Applications and check System Settings → General → Login Items."
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// Show live Claude Code sessions in the notch. Installs hook entries into
    /// ~/.claude/settings.json (removed again when turned off).
    @Published var claudeSessionsEnabled: Bool {
        didSet { defaults.set(claudeSessionsEnabled, forKey: Keys.claudeSessions) }
    }

    @Published var codexSessionsEnabled: Bool {
        didSet { defaults.set(codexSessionsEnabled, forKey: Keys.codexSessions) }
    }

    /// How far the podcast transport buttons jump, in seconds. Spotify's own player
    /// is fixed at 15 both ways; 30 is the other interval people reach for, so we
    /// offer both rather than hard-coding one.
    @Published var podcastSkipSeconds: Int {
        didSet { defaults.set(podcastSkipSeconds, forKey: Keys.podcastSkip) }
    }

    /// The intervals offered in Settings. `gobackward.N` / `goforward.N` SF Symbols
    /// only exist for a fixed set of values, and these two are in it.
    static let podcastSkipOptions = [15, 30]

    private enum Keys {
        static let claudeSessions = "settings.claudeSessionsEnabled"
        static let codexSessions = "settings.codexSessionsEnabled"
        static let copyScreenshot = "settings.copyScreenshotToClipboard"
        static let podcastSkip = "settings.podcastSkipSeconds"
    }

    /// The managed folder we point macOS at when routing is enabled.
    static var managedScreenshotURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Screenshots")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // First launch: clipboard-copy preserves the prior always-on behavior.
        if defaults.object(forKey: Keys.copyScreenshot) == nil {
            defaults.set(true, forKey: Keys.copyScreenshot)
        }
        copyScreenshotToClipboard = defaults.bool(forKey: Keys.copyScreenshot)
        if defaults.object(forKey: Keys.claudeSessions) == nil {
            defaults.set(true, forKey: Keys.claudeSessions)
        }
        claudeSessionsEnabled = defaults.bool(forKey: Keys.claudeSessions)
        if defaults.object(forKey: Keys.codexSessions) == nil {
            defaults.set(true, forKey: Keys.codexSessions)
        }
        codexSessionsEnabled = defaults.bool(forKey: Keys.codexSessions)
        // Default to Spotify's own 15 s. Guard against a stale/garbage value so the
        // button never asks for an SF Symbol that doesn't exist.
        let storedSkip = defaults.integer(forKey: Keys.podcastSkip)
        podcastSkipSeconds = Self.podcastSkipOptions.contains(storedSkip) ? storedSkip : 15
        // Routing reflects the live system pref — the user (or this app) may have
        // already pointed `screencapture` somewhere; mirror reality, don't overwrite it.
        routeScreenshotsToFolder = Self.detectScreenshotRouting()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// True when `com.apple.screencapture.location` is already our managed path.
    private static func detectScreenshotRouting() -> Bool {
        guard let raw = CFPreferencesCopyAppValue("location" as CFString,
                                                  "com.apple.screencapture" as CFString) as? String
        else { return false }
        return (raw as NSString).expandingTildeInPath == managedScreenshotURL.path
    }

}
