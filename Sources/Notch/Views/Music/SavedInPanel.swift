import SwiftUI

/// The unfolded section under the transport controls: which playlists hold the
/// current track (Liked Songs included) plus the rest of your playlists to add
/// it to — Spotify's "Add to playlist" dialog, sans new-playlist. Also hosts
/// the connect / error states that precede having an answer.
struct SavedInPanel: View {
    @EnvironmentObject private var spotify: SpotifyLibrary
    let accent: Color
    let onClose: () -> Void

    private static let slide = Animation.spring(response: 0.4, dampingFraction: 0.82)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("SAVED IN")
                    .font(.system(size: 8.5, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                TransportButton(symbol: "xmark", size: 9, enabled: true, action: onClose)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var content: some View {
        switch spotify.state {
        case .disconnected:
            HStack(spacing: 8) {
                Text(spotify.hasClientID
                     ? "Connect Spotify to see where this song is saved."
                     : "Set up Spotify in Settings to see where this song is saved.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(spotify.hasClientID ? "Connect" : "Set Up…") {
                    if spotify.hasClientID {
                        spotify.connect()
                    } else {
                        AppDelegate.shared?.showSettingsWindow()
                    }
                }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(accent.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
            }
            .frame(maxHeight: .infinity)
        case .connecting:
            HStack(spacing: 8) {
                Text("Finish logging in in your browser…")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Retry") { spotify.connect() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.white.opacity(0.14), in: Capsule())
                    .foregroundStyle(.white)
            }
            .frame(maxHeight: .infinity)
        case .connected:
            if spotify.accessDenied {
                statusLine("Spotify denied access (403) — your account isn't allowlisted for this app. Set up your own Spotify app in Settings → Spotify.")
            } else if spotify.membership.trackID == nil {
                statusLine("This track isn't playing from Spotify.")
            } else if !spotify.membership.hasAny {
                statusLine(spotify.isSyncing ? "Syncing your playlists…"
                                             : "Not saved in any of your playlists.")
            } else {
                let saved = spotify.membership.playlists
                let others = spotify.allPlaylists.filter { p in !saved.contains(where: { $0.id == p.id }) }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        PlaylistToggleRow(art: .liked, name: "Liked Songs",
                                          contained: spotify.membership.liked == true) {
                            withAnimation(Self.slide) {
                                spotify.setLiked(!(spotify.membership.liked == true))
                            }
                        }
                        // One ForEach spanning both sections: a toggle is then a pure
                        // reorder of stable identities, which SwiftUI animates as a
                        // slide — splitting into two ForEaches would make it a
                        // remove+insert pair and leave a fading ghost of the row.
                        ForEach(saved + others) { ref in
                            let isSaved = saved.contains { $0.id == ref.id }
                            if ref.id == others.first?.id {
                                Text("ADD TO")
                                    .font(.system(size: 8, weight: .bold))
                                    .kerning(0.8)
                                    .foregroundStyle(.white.opacity(0.35))
                                    .padding(.top, 6)
                            }
                            PlaylistToggleRow(art: .cover(ref.image), name: ref.name, contained: isSaved) {
                                withAnimation(Self.slide) {
                                    isSaved ? spotify.removeFromPlaylist(ref)
                                            : spotify.addToPlaylist(ref)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private func statusLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// One playlist entry, Spotify-dialog style: cover art, name, and a trailing
/// indicator. Contained rows carry the green check (hover flips it to a red ⊖ =
/// remove); the rest show an empty circle that fills in when clicked (= add).
/// The whole row is the hit target.
private struct PlaylistToggleRow: View {
    enum Art { case liked, cover(String?) }

    let art: Art
    let name: String
    let contained: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    private static let artSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 8) {
            artwork
                .frame(width: Self.artSize, height: Self.artSize)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(contained || hovering ? 1 : 0.7))
                .lineLimit(1)
            Spacer(minLength: 0)
            // Two stacked symbols cross-faded by `contained` rather than one Image
            // whose symbol name changes: a name swap re-renders discontinuously and
            // the indicator teleports instead of sliding with the row, while
            // opacity/scale interpolate cleanly inside the reorder spring.
            ZStack {
                Image(systemName: "circle")
                    .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.35))
                    .opacity(contained ? 0 : 1)
                Image(systemName: hovering ? "minus.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(hovering ? Color(red: 1.0, green: 0.36, blue: 0.34)
                                              : SaveButton.spotifyGreen)
                    .contentTransition(.symbolEffect(.replace))
                    .opacity(contained ? 1 : 0)
                    .scaleEffect(contained ? 1 : 0.3)
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .trackedHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
        .onTapGesture {
            // Drop hover styling immediately: the row slides away from the cursor
            // on toggle, and a lingering hover state paints the wrong indicator
            // (white ○ / red ⊖) until onHover(false) catches up mid-slide.
            hovering = false
            onToggle()
        }
    }

    @ViewBuilder private var artwork: some View {
        switch art {
        case .liked:
            // Spotify's Liked Songs tile: heart on a violet gradient.
            ZStack {
                LinearGradient(colors: [Color(red: 0.27, green: 0.16, blue: 0.87),
                                        Color(red: 0.75, green: 0.83, blue: 0.92)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "heart.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
            }
        case .cover(let urlString):
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.white.opacity(0.08)
                }
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }
}
