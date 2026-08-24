import SwiftUI

/// Standalone preferences window for Notch. Currently scoped to the screenshot
/// features; more sections will land here as toggleable behaviors get added.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var spotify: SpotifyLibrary
    @State private var clientIDDraft = ""
    @State private var showCleanupConfirm = false
    @State private var pendingCleanupCount = 0

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
                Toggle(isOn: $settings.claudeSessionsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show live Claude Code sessions")
                        Text("Adds hook entries to ~/.claude/settings.json so each session reports what it's doing. Sessions already running pick this up on their next restart.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Claude Code")
            }
            Section {
                Toggle(isOn: $settings.routeScreenshotsToFolder) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save screenshots to a Screenshots folder")
                        Text("Routes captures into ~/Pictures/Screenshots — keeps your Desktop clean, no folder permission needed.")
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
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clean up screenshots")
                        Text("Moves every screenshot in the current folder to the Trash.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clean Up…") {
                        pendingCleanupCount = ScreenshotWatcher.screenshotsInCurrentFolder().count
                        showCleanupConfirm = pendingCleanupCount > 0
                    }
                    .confirmationDialog(
                        "Move \(pendingCleanupCount) screenshot\(pendingCleanupCount == 1 ? "" : "s") to the Trash?",
                        isPresented: $showCleanupConfirm, titleVisibility: .visible
                    ) {
                        Button("Move to Trash", role: .destructive) {
                            _ = ScreenshotWatcher.trashAllScreenshots()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Only files macOS created as screenshots are touched. You can restore them from the Trash.")
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
                    } else if spotify.hasClientID {
                        Button(spotify.state == .connecting ? "Retry Login…" : "Connect…") {
                            spotify.connect()
                        }
                    }
                }
                if spotify.state == .connecting {
                    Text("Finish logging in in your browser. If nothing happens, check that your Spotify app's redirect URI is exactly \(SpotifyLibrary.redirectURI).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set up your Spotify app")
                    Text("""
                    Spotify limits third-party apps to a handful of users, so Notch connects \
                    through a Spotify app you own (free, needs Spotify Premium):
                    1. On the Spotify dashboard, create an app.
                    2. Set its Redirect URI to the address below (Web API).
                    3. Paste its Client ID here, apply, then Connect above.
                    Applying a change signs you out so you can reconnect under the new app.
                    """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Open Spotify Dashboard") {
                            NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!)
                        }
                        Button("Copy Redirect URI") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(SpotifyLibrary.redirectURI, forType: .string)
                        }
                        .help(SpotifyLibrary.redirectURI)
                    }
                    HStack {
                        TextField("Client ID", text: $clientIDDraft)
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
        case .disconnected:  return spotify.hasClientID ? "Spotify account"
                                                        : "Spotify account · setup needed below"
        }
    }
}
