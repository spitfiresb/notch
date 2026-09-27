import AppKit
import SwiftUI

/// Hosts `SettingsView` in a regular macOS window. Singleton-presented so
/// repeated gear-clicks bring the existing window forward instead of stacking
/// new ones.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static var shared: SettingsWindowController?

    convenience init(settings: SettingsStore, spotify: SpotifyLibrary, agents: AgentSessionStore) {
        let root = SettingsView()
            .environmentObject(settings)
            .environmentObject(spotify)
            .environmentObject(agents)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Notch Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    /// Show the settings window, bringing the existing one forward if already open.
    /// `LSUIElement` apps need an explicit activation or the window appears unfocused
    /// behind whatever the user was doing.
    static func present(settings: SettingsStore, spotify: SpotifyLibrary, agents: AgentSessionStore) {
        if let existing = shared {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SettingsWindowController(settings: settings, spotify: spotify, agents: agents)
        shared = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}
