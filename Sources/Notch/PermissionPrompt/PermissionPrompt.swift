import AppKit
import Foundation

/// The System Settings privacy panes the onboarding can walk the user into.
enum PermissionPrompt: String, CaseIterable, Sendable {
    case accessibility = "Privacy_Accessibility"
    case automation = "Privacy_Automation"
    case filesAndFolders = "Privacy_FilesAndFolders"

    var title: String {
        switch self {
        case .accessibility:   "Accessibility"
        case .automation:      "Automation"
        case .filesAndFolders: "Files & Folders"
        }
    }

    /// What the user actually flips in the pane (shown in the overlay copy).
    var toggleLabel: String {
        switch self {
        case .accessibility:   "Accessibility"
        case .automation:      "Spotify"
        case .filesAndFolders: "folder"
        }
    }

    func openSettings() { Permissions.open(rawValue) }
}

struct PermissionPromptHostApp: Sendable {
    let displayName: String
    let bundleURL: URL
    let icon: NSImage

    static func current(bundle: Bundle = .main) -> PermissionPromptHostApp {
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: bundle.bundleURL.path)
        icon.size = NSSize(width: 48, height: 48)
        return PermissionPromptHostApp(displayName: displayName, bundleURL: bundle.bundleURL, icon: icon)
    }
}
