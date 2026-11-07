import AppKit

// Pure-AppKit entry point so we have full control over the borderless overlay panel.
@MainActor private enum Bootstrap {
    static let delegate = AppDelegate()
}

let app = NSApplication.shared
MainActor.assumeIsolated {
    // Before constructing AppEnvironment: no hooks, login items or services from a DMG.
    guard LaunchSafety.mayLaunch() else { exit(0) }
    app.delegate = Bootstrap.delegate
    app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar item
}
app.run()
