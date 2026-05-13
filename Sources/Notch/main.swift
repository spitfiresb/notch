import AppKit

// Pure-AppKit entry point so we have full control over the borderless overlay panel.
@MainActor private enum Bootstrap {
    static let delegate = AppDelegate()
}

let app = NSApplication.shared
MainActor.assumeIsolated {
    app.delegate = Bootstrap.delegate
    app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar item
}
app.run()
