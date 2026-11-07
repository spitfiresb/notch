import AppKit

enum LaunchSafety {
    static func needsInstallation(url: URL, readOnlyVolume: Bool) -> Bool {
        url.pathExtension == "app" && (readOnlyVolume || url.pathComponents.contains("AppTranslocation"))
    }

    @MainActor static func mayLaunch() -> Bool {
        let url = Bundle.main.bundleURL
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        guard !needsInstallation(url: url, readOnlyVolume: readOnly) else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Move Notch to Applications first"
            alert.informativeText = "Drag Notch into the Applications folder, eject the disk image, then open Notch from Applications. This keeps permissions and launch at login attached to your installed copy."
            alert.addButton(withTitle: "Open Applications")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
            }
            return false
        }
        if let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            if let installed = existing.bundleURL {
                NSWorkspace.shared.openApplication(at: installed, configuration: .init())
            }
            return false
        }
        return true
    }
}
