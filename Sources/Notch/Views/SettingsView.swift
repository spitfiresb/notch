import SwiftUI

/// Standalone preferences window for Notch. Currently scoped to the screenshot
/// features; more sections will land here as toggleable behaviors get added.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.routeScreenshotsToFolder) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save screenshots to a Screenshots folder")
                        Text("Routes captures into ~/Desktop/Screenshots so your Desktop stays clean.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.copyScreenshotToClipboard) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copy new screenshots to the clipboard")
                        Text("Paste a screenshot the moment you've taken it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Screenshots")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 260)
    }
}
