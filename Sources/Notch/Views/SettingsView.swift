import SwiftUI

/// Standalone preferences window for Notch. Currently scoped to the screenshot
/// features; more sections will land here as toggleable behaviors get added.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var spotify: SpotifyLibrary

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                        Text("Keeps Notch running across restarts and shutdowns.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("General")
            }
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
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spotifyStatusTitle)
                        Text(spotify.accessDenied
                             ? "Spotify is refusing API access (403). In Development mode only allowlisted accounts work — on developer.spotify.com open the app → User Management and add the Spotify account you log in with (or log in as the account that owns the app)."
                             : "Shows whether the current song is Liked and which of your playlists it's in.")
                            .font(.caption)
                            .foregroundStyle(spotify.accessDenied ? .red : .secondary)
                    }
                    Spacer()
                    if spotify.state == .connected {
                        Button("Sync Now") { Task { await spotify.sync(force: true) } }
                            .disabled(spotify.isSyncing)
                        Button("Disconnect") { spotify.disconnect() }
                    } else {
                        Button(spotify.state == .connecting ? "Retry Login…" : "Connect…") {
                            spotify.connect()
                        }
                    }
                }
            } header: {
                Text("Spotify")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 420)
    }

    private var spotifyStatusTitle: String {
        switch spotify.state {
        case .connected:
            if spotify.isSyncing { return "Connected · syncing playlists…" }
            return "Connected · \(spotify.playlistCount) playlists indexed"
        case .connecting:    return "Connecting to Spotify…"
        case .disconnected:  return "Spotify account"
        }
    }
}
