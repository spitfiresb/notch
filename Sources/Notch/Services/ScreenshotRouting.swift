import Foundation

/// Saves just the preference we own. Never resets a folder chosen outside Notch.
struct ScreenshotRouting {
    let defaults: UserDefaults
    let managedPath: String
    let read: () -> String?
    let write: (String?) throws -> Void
    let prepareDirectory: () throws -> Void
    private let savedKey = "screenshots.previousLocation.saved"
    private let locationKey = "screenshots.previousLocation"

    @MainActor static var current: ScreenshotRouting {
        ScreenshotRouting(defaults: .standard, managedPath: SettingsStore.managedScreenshotURL.path,
            read: { CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String },
            write: { path in
                CFPreferencesSetAppValue("location" as CFString, path as CFString?, "com.apple.screencapture" as CFString)
                guard CFPreferencesAppSynchronize("com.apple.screencapture" as CFString) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            },
            prepareDirectory: {
                try FileManager.default.createDirectory(at: SettingsStore.managedScreenshotURL,
                                                        withIntermediateDirectories: true)
            })
    }

    func setEnabled(_ enabled: Bool) throws {
        let current = read()
        let isManaged = current.map { ($0 as NSString).expandingTildeInPath == managedPath } ?? false
        if enabled {
            guard !isManaged else { return }
            try prepareDirectory()
            // Save a nil value too: that represents the macOS default Desktop.
            defaults.set(current, forKey: locationKey)
            defaults.set(true, forKey: savedKey)
            try write(managedPath)
        } else {
            if isManaged {
                try write(defaults.bool(forKey: savedKey) ? defaults.string(forKey: locationKey) : nil)
            }
            defaults.removeObject(forKey: savedKey)
            defaults.removeObject(forKey: locationKey)
        }
    }
}
