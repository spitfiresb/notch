import SwiftUI

/// Standalone preferences window for Notch. Currently scoped to the screenshot
/// features; more sections will land here as toggleable behaviors get added.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var spotify: SpotifyLibrary
    @State private var clientIDDraft = ""

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
                             ? "Spotify is refusing API access (403). This usually means your Spotify account isn't allowlisted on the app you're connecting through — use your own Spotify app below."
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Use your own Spotify app")
                    Text("""
                    Spotify limits third-party apps to a handful of users, so Notch works with \
                    a Spotify app you own (free, needs Spotify Premium):
                    1. On developer.spotify.com/dashboard, create an app.
                    2. Set its Redirect URI to \(SpotifyLibrary.redirectURI) (Web API).
                    3. Paste its Client ID here, apply, then Connect above.
                    Applying a change signs you out so you can reconnect under the new app.
                    """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("Client ID (leave blank for the built-in app)", text: $clientIDDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .autocorrectionDisabled()
                            .onSubmit { spotify.setCustomClientID(clientIDDraft) }
                        Button("Apply") { spotify.setCustomClientID(clientIDDraft) }
                            .disabled(clientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                      == spotify.customClientID)
                    }
                }
            } header: {
                Text("Spotify")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .onAppear { clientIDDraft = spotify.customClientID }
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
