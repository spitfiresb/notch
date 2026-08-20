import AppKit
import Foundation

// Portions of the PermissionPrompt subsystem are derived from MIT-licensed software:
//
// Copyright (c) 2026 Alex Rankine
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

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
