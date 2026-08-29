import SwiftUI

struct MusicTabView: View {
    /// Shared with `CollapsedPeek` so `matchedGeometryEffect` can morph the
    /// artwork and bars between the peek's small layout and our larger one.
    let namespace: Namespace.ID
    @EnvironmentObject private var music: NowPlayingManager
    @EnvironmentObject private var spotify: SpotifyLibrary
    @EnvironmentObject private var notch: NotchState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var claude: ClaudeSessionStore
    private var info: NowPlayingInfo { music.info }

    private static let trackFade: Animation = .easeInOut(duration: 0.34)

    var body: some View {
        VStack(spacing: 5) {
            // Top: art · title/artist · dancing bars
            HStack(spacing: 9) {
                artwork
                    .frame(width: 36, height: 36)
                    .clipShape(Rectangle())
                    .matchedGeometryEffect(id: "chromeArt", in: namespace)

                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(info.hasContent ? info.title : "Nothing playing",
                                font: .system(size: 13.5, weight: .semibold))
                    if info.hasContent {
                        MarqueeText(info.artist, font: .system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 4)

                if info.hasContent {
                    DancingBars(color: music.displayAccent,
                                isPlaying: info.isPlaying)
                        .frame(width: 20, height: 14)
                        .matchedGeometryEffect(id: "chromeBars", in: namespace)
                }
            }

            // Middle: elapsed · progress · remaining (draggable scrubber)
            MusicProgressLine(info: info) { music.seek(to: $0) }

            // Bottom: transport centred, save button at the left edge. Podcasts get
            // Spotify's own episode layout instead -- speed, ±15 s, prev/next episode
            // -- and no save button (Spotify greys it out for episodes too).
            ZStack {
                if info.isPodcast {
                    HStack(spacing: 14) {
                        TransportButton(glyph: .text(rateLabel), size: 12, enabled: info.hasContent) {
                            music.cyclePlaybackRate()
                        }
                        TransportButton(symbol: "gobackward.\(skipSeconds)", size: 13, enabled: info.hasContent) {
                            music.skip(by: -Double(skipSeconds))
                        }
                        TransportButton(symbol: "backward.end.fill", size: 13, enabled: info.hasContent) { music.previous() }
                        PlayPauseButton(isPlaying: info.isPlaying, enabled: info.hasContent) {
                            music.togglePlayPause()
                        }
                        TransportButton(symbol: "forward.end.fill", size: 13, enabled: info.hasContent) { music.next() }
                        TransportButton(symbol: "goforward.\(skipSeconds)", size: 13, enabled: info.hasContent) {
                            music.skip(by: Double(skipSeconds))
                        }
                    }
                    // The Claude spinner (SessionsCorner) overlays the bottom-right of
                    // the tab area while a session runs; the six-wide row reaches under
                    // it, so give up that strip and re-centre in what's left.
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, claude.anyActive ? Self.spinnerReserve : 0)
                    .animation(.spring(response: 0.36, dampingFraction: 0.8), value: claude.anyActive)
                } else {
                    HStack(spacing: 26) {
                        TransportButton(symbol: "backward.fill", size: 13, enabled: info.hasContent) { music.previous() }
                        PlayPauseButton(isPlaying: info.isPlaying, enabled: info.hasContent) {
                            music.togglePlayPause()
                        }
                        TransportButton(symbol: "forward.fill", size: 13, enabled: info.hasContent) { music.next() }
                    }
                    HStack {
                        SaveButton(enabled: spotifyActionsEnabled) {
                            notch.musicPanelExpanded.toggle()
                        }
                        Spacer()
                    }
                }
            }
            .frame(height: 30)

            // The notch grows downward (NotchRootView sizes the blob off
            // `musicPanelExpanded`) and the playlist panel fills the new space —
            // the controls above never move.
            if notch.musicPanelExpanded {
                SavedInPanel(accent: music.displayAccent) {
                    notch.musicPanelExpanded = false
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One fade applies to every track-driven change: art swap, title/artist
        // text cross-fade, and the dancing-bars accent colour interpolation.
        .animation(Self.trackFade, value: music.displayKey)
        .animation(Self.trackFade, value: info.title)
        .animation(Self.trackFade, value: info.artist)
        .animation(Self.trackFade, value: music.displayAccent)
    }

    private var skipSeconds: Int { settings.podcastSkipSeconds }

    /// SessionsCorner's strip is 24 pt wide; this leaves the row's normal 14 pt
    /// gap between the last button and the spinner.
    private static let spinnerReserve: CGFloat = 24 + 14

    /// "1x", "1.5x" -- trailing zeros dropped, as Spotify shows it.
    private var rateLabel: String {
        let r = info.playbackRate
        let s = r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
        return s + "×"
    }

    /// Heart / saved-in make sense once we can name the track on Spotify — or
    /// always, pre-connect, so the buttons can lead into the connect flow.
    private var spotifyActionsEnabled: Bool {
        info.hasContent && (spotify.state != .connected || info.spotifyTrackID != nil)
    }

    /// Plain content for the artwork slot — no `.id`/`.transition` here because
    /// that pair runs its own opacity fade when this view is inserted, which
    /// conflicts with the matched-geometry morph during the open transition.
    /// Also no `.aspectRatio` — album art is square in practice and the layout
    /// constraint fought with matched-geometry's frame interpolation.
    @ViewBuilder private var artwork: some View {
        if let image = music.displayArt {
            Image(nsImage: image).resizable()
        } else {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "music.note")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}
