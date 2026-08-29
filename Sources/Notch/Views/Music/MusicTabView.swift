import SwiftUI

struct MusicTabView: View {
    /// Shared with `CollapsedPeek` so `matchedGeometryEffect` can morph the
    /// artwork and bars between the peek's small layout and our larger one.
    let namespace: Namespace.ID
    /// Side-docked: the open notch is a slim upright strip, so the tab stacks
    /// down it — art, title/artist turned like a book spine, the lengthwise
    /// meter, then the transport buttons one under another. No scrubber or
    /// playlist panel; there's no room, and the podcast skip buttons cover
    /// getting around an episode.
    var vertical: Bool = false
    @EnvironmentObject private var music: NowPlayingManager
    @EnvironmentObject private var spotify: SpotifyLibrary
    @EnvironmentObject private var notch: NotchState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var claude: ClaudeSessionStore
    private var info: NowPlayingInfo { music.info }

    private static let trackFade: Animation = .easeInOut(duration: 0.34)

    var body: some View {
        if vertical { strip } else { landscape }
    }

    private var strip: some View {
        VStack(spacing: 8) {
            artwork
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .matchedGeometryEffect(id: "chromeArt", in: namespace)
            spine
            LengthwiseBars(color: music.displayAccent, isPlaying: info.isPlaying,
                           reach: 40, barWidth: 3, spacing: 3, fromRight: notch.dock == .right)
                .matchedGeometryEffect(id: "chromeBars", in: namespace)
                .opacity(info.hasContent ? 1 : 0)
            transportStack
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Self.trackFade, value: music.displayKey)
        .animation(Self.trackFade, value: info.title)
        .animation(Self.trackFade, value: info.artist)
        .animation(Self.trackFade, value: music.displayAccent)
    }

    /// Title and artist rotated a quarter turn clockwise so they read down the
    /// strip like a spine. Laid out flat at `spineLength` × 30, then turned and
    /// re-framed to the space the turned block actually occupies.
    private static let spineLength: CGFloat = 96
    private var spine: some View {
        VStack(spacing: 1) {
            MarqueeText(info.hasContent ? info.title : "Nothing playing",
                        font: .system(size: 12, weight: .semibold))
            if info.hasContent {
                MarqueeText(info.artist, font: .system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: Self.spineLength, height: 30)
        .rotationEffect(.degrees(90))
        .frame(width: 30, height: Self.spineLength)
    }

    /// Transport one button under another. Podcasts get the full Spotify
    /// episode set (speed · ⟲ · ⏮ · ⏯ · ⏭ · ⟳); songs just ⏮ ⏯ ⏭.
    private var transportStack: some View {
        VStack(spacing: 2) {
            if info.isPodcast {
                TransportButton(glyph: .text(rateLabel), size: 11, enabled: info.hasContent) {
                    music.cyclePlaybackRate()
                }
                TransportButton(symbol: "gobackward.\(skipSeconds)", size: 12, enabled: info.hasContent) {
                    music.skip(by: -Double(skipSeconds))
                }
                TransportButton(symbol: "backward.end.fill", size: 12, enabled: info.hasContent) { music.previous() }
            } else {
                TransportButton(symbol: "backward.fill", size: 12, enabled: info.hasContent) { music.previous() }
            }
            PlayPauseButton(isPlaying: info.isPlaying, enabled: info.hasContent) {
                music.togglePlayPause()
            }
            if info.isPodcast {
                TransportButton(symbol: "forward.end.fill", size: 12, enabled: info.hasContent) { music.next() }
                TransportButton(symbol: "goforward.\(skipSeconds)", size: 12, enabled: info.hasContent) {
                    music.skip(by: Double(skipSeconds))
                }
            } else {
                TransportButton(symbol: "forward.fill", size: 12, enabled: info.hasContent) { music.next() }
            }
        }
    }

    private var landscape: some View {
        VStack(spacing: 5) {
            landscapeHeader

            // Middle: elapsed · progress · remaining (draggable scrubber)
            MusicProgressLine(info: info) { music.seek(to: $0) }

            transportRow

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

    private var landscapeHeader: some View {
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
    }

    /// Bottom: transport centred, save button at the left edge. Podcasts get
    /// Spotify's own episode layout instead -- speed, ±15 s, prev/next episode
    /// -- and no save button (Spotify greys it out for episodes too).
    private var transportRow: some View {
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
