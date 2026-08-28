import AppKit
import Combine
import CoreImage
import SwiftUI

struct NowPlayingInfo: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var isPlaying = false
    var artwork: NSImage?
    var artworkKey: String?     // url or track id, so we can avoid re-fetching artwork
    var accentColor: Color?     // vibrant tint derived from the artwork
    var source = ""             // "Spotify", "Now Playing", …
    var spotifyTrackID: String? // bare id (no "spotify:track:" prefix) when the track is resolvable in Spotify
    var duration: Double?       // total seconds
    var elapsed: Double?        // seconds at `elapsedAt`
    var elapsedAt: Date?        // wall-clock time when `elapsed` was sampled
    var isPodcast = false       // spoken-word item: transport skips by seconds, not tracks
    var hasContent: Bool { !title.isEmpty }

    /// Where the playhead is *right now*: the last sampled position, extrapolated by
    /// the wall-clock time since it was taken (we only refresh every few seconds).
    var liveElapsed: Double {
        guard let e = elapsed else { return 0 }
        guard isPlaying, let at = elapsedAt else { return e }
        return e + Date().timeIntervalSince(at)
    }
}

/// Reads & controls whatever is playing. Prefers the system "Now Playing" data
/// (the private MediaRemote framework, same source the Control Center widget uses);
/// falls back to talking to the Spotify desktop app directly via Apple Events when
/// the system data is unavailable (recent macOS locks MediaRemote down for
/// un-entitled apps).
@MainActor
final class NowPlayingManager: ObservableObject {
    @Published private(set) var info = NowPlayingInfo()

    /// Last non-nil artwork seen — survives the brief gap during a track change so views
    /// can cross-fade between two real images instead of flashing through a placeholder.
    /// Cleared only when playback truly stops (`info.hasContent == false`).
    @Published private(set) var displayArt: NSImage?
    /// Same idea for the album-art accent: holds the previous track's tint until the new
    /// one is computed, so the dancing bars don't flash white between songs.
    @Published private(set) var displayAccent: Color = .white
    /// Stable identity for the *currently displayed* track. Changes only when artwork or
    /// title flips to a new song — views use it to drive cross-fade transitions.
    @Published private(set) var displayKey: String = ""

    private let mr = MediaRemoteBridge()
    private var pollTimer: Timer?
    private var usingSpotifyFallback = false
    private var artworkCache: [String: NSImage] = [:]
    private var accentCache: [String: Color] = [:]
    /// artist+title → Spotify track id, so the AppleScript id lookup on the
    /// MediaRemote path runs once per item instead of on every refresh. We cache the
    /// full URI rather than the bare track id because episodes have no track id --
    /// under an id-only cache a podcast re-probed Spotify on every single refresh.
    private var spotifyURICache: [String: String] = [:]

    func start() {
        mr.registerForNotifications { [weak self] in self?.refresh() }
        // Spotify announces every play/pause/track change via a distributed
        // notification, so we refresh on events instead of a fast poll. Each
        // refresh on the Spotify-fallback path is a *synchronous* AppleScript
        // → Apple Events round-trip on the main thread (~40 ms); at the old
        // 3 s poll that was a steady ~3% CPU. The slow poll below is only a
        // recovery net (missed notification, scrubber drift).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func togglePlayPause() {
        // Optimistic flip — the icon swap & scrubber should react immediately,
        // before the round-trip to MediaRemote / Spotify completes.
        if info.isPlaying, let e = info.elapsed, let at = info.elapsedAt {
            info.elapsed = e + Date().timeIntervalSince(at)   // freeze scrubber
        }
        info.elapsedAt = Date()
        info.isPlaying.toggle()
        command(.togglePlayPause, spotify: "playpause")
    }
    func next()     { command(.nextTrack, spotify: "next track") }
    func previous() { command(.previousTrack, spotify: "previous track") }

    /// Jump within the current item -- forward for a positive `seconds`, back for a
    /// negative one. This is what the transport buttons do for podcasts, where
    /// next/previous *episode* is almost never what you want mid-listen.
    func skip(by seconds: Double) {
        var target = info.liveElapsed + seconds
        if let d = info.duration, d > 0 { target = min(target, d) }
        seek(to: target)   // `seek` clamps the low end at 0
    }

    /// Seek the current track to `seconds`. Tries MediaRemote first; falls back to
    /// Spotify Apple Events if the system path isn't available.
    func seek(to seconds: Double) {
        let s = max(0, seconds)
        if usingSpotifyFallback || !mr.setElapsed(s) {
            SpotifyBridge.seek(to: s)
        }
        // Optimistic local update so the scrubber doesn't snap back before the next poll.
        info.elapsed = s
        info.elapsedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    private func command(_ c: MediaRemoteBridge.Command, spotify verb: String) {
        if usingSpotifyFallback || !mr.sendCommand(c) {
            SpotifyBridge.command(verb)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refresh() }
    }

    func refresh() {
        mr.getNowPlaying { [weak self] mrInfo in
            // mr.getNowPlaying calls back on the main queue.
            guard let self else { return }
            if var mrInfo, mrInfo.hasContent {
                self.usingSpotifyFallback = false
                self.attachArtwork(&mrInfo)
                self.attachSpotifyMetadata(&mrInfo)
                self.info = mrInfo
            } else if let (spot, artURL) = SpotifyBridge.fetch() {
                self.usingSpotifyFallback = true
                var spot = spot
                self.attachArtwork(&spot)
                self.info = spot
                if let artURL { self.loadArtwork(from: artURL, key: spot.artworkKey) }
            } else {
                self.usingSpotifyFallback = false
                self.info = NowPlayingInfo()
            }
            self.syncDisplayState()
        }
    }

    /// Pull `info` into the `display*` buffers without ever passing through nil, so the
    /// UI always has a real image / color to draw and views can animate the swap.
    private func syncDisplayState() {
        if !info.hasContent {
            displayArt = nil
            displayAccent = .white
            displayKey = ""
            return
        }
        if let art = info.artwork { displayArt = art }
        if let accent = info.accentColor { displayAccent = accent }
        let key = info.artworkKey ?? "\(info.title)|\(info.artist)"
        if key != displayKey { displayKey = key }
    }

    private func attachArtwork(_ info: inout NowPlayingInfo) {
        if info.artwork == nil, let key = info.artworkKey, let cached = artworkCache[key] {
            info.artwork = cached
        }
        if let art = info.artwork, let key = info.artworkKey { artworkCache[key] = art }
        if let key = info.artworkKey, let cached = accentCache[key] {
            info.accentColor = cached
        } else if let art = info.artwork {
            let accent = ColorAccent.extract(from: art)
            info.accentColor = accent
            if let key = info.artworkKey { accentCache[key] = accent }
        }
    }

    /// The MediaRemote payload has no Spotify id, but if Spotify is the thing
    /// playing we can ask it directly — one synchronous Apple Events round-trip
    /// per new track (same cost profile as the fallback path's fetch). The title
    /// must match so we don't mislabel some other app's audio.
    private func attachSpotifyMetadata(_ info: inout NowPlayingInfo) {
        let key = "\(info.artist)\u{1}\(info.title)"
        if let cached = spotifyURICache[key] {
            apply(spotifyURI: cached, to: &info)
            return
        }
        guard SpotifyBridge.isRunning,
              let (id, name) = SpotifyBridge.currentTrackIDAndName(),
              name == info.title else { return }
        spotifyURICache[key] = id
        apply(spotifyURI: id, to: &info)
    }

    /// A Spotify URI tells us both things we want: the bare track id (nil for
    /// anything that isn't a song) and whether this is a podcast episode. Only ever
    /// sets `isPodcast` to true, so a MediaRemote media-type hit isn't undone here.
    private func apply(spotifyURI uri: String, to info: inout NowPlayingInfo) {
        info.spotifyTrackID = SpotifyBridge.bareTrackID(uri)
        if SpotifyBridge.isEpisodeURI(uri) { info.isPodcast = true }
    }

    private func loadArtwork(from url: URL, key: String?) {
        if let key, artworkCache[key] != nil { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            let accent = ColorAccent.extract(from: image)
            DispatchQueue.main.async {
                guard let self else { return }
                if let key {
                    self.artworkCache[key] = image
                    self.accentCache[key] = accent
                }
                if self.info.artworkKey == key || self.info.artwork == nil {
                    self.info.artwork = image
                    self.info.accentColor = accent
                    self.syncDisplayState()
                }
            }
        }.resume()
    }
}

// MARK: - Album-art accent color

/// Extracts a vibrant accent color from an album cover by averaging it and then
/// boosting saturation / brightness so it pops on the dark notch.
enum ColorAccent {
    static func extract(from image: NSImage) -> Color {
        guard let tiff = image.tiffRepresentation,
              let ciImage = CIImage(data: tiff) else { return .white }
        let extent = ciImage.extent
        let params: [String: Any] = [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: extent),
        ]
        guard let output = CIFilter(name: "CIAreaAverage", parameters: params)?.outputImage
        else { return .white }
        var rgba = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        ctx.render(output, toBitmap: &rgba, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let avg = NSColor(red: CGFloat(rgba[0]) / 255,
                          green: CGFloat(rgba[1]) / 255,
                          blue: CGFloat(rgba[2]) / 255,
                          alpha: 1).usingColorSpace(.deviceRGB)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        avg?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let punchedS = min(1, max(0.55, s * 1.4))
        let punchedB = min(0.95, max(0.75, b * 1.25))
        return Color(nsColor: NSColor(hue: h, saturation: punchedS, brightness: punchedB, alpha: 1))
    }
}

// MARK: - MediaRemote (private framework) bridge

final class MediaRemoteBridge {
    enum Command: Int { case play = 0, pause = 1, togglePlayPause = 2, stop = 3, nextTrack = 4, previousTrack = 5 }

    private typealias GetInfoFn     = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void
    private typealias GetPlayingFn  = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (Int, CFDictionary?) -> Bool
    private typealias RegisterFn    = @convention(c) (DispatchQueue) -> Void
    private typealias SetElapsedFn  = @convention(c) (Double) -> Void

    private let getInfoFn: GetInfoFn?
    private let getPlayingFn: GetPlayingFn?
    private let sendCommandFn: SendCommandFn?
    private let registerFn: RegisterFn?
    private let setElapsedFn: SetElapsedFn?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let ptr = dlsym(handle, name) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }
        getInfoFn     = sym("MRMediaRemoteGetNowPlayingInfo", as: GetInfoFn.self)
        getPlayingFn  = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: GetPlayingFn.self)
        sendCommandFn = sym("MRMediaRemoteSendCommand", as: SendCommandFn.self)
        registerFn    = sym("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterFn.self)
        setElapsedFn  = sym("MRMediaRemoteSetElapsedTime", as: SetElapsedFn.self)
    }

    func registerForNotifications(_ onChange: @escaping () -> Void) {
        registerFn?(DispatchQueue.main)
        for name in ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                     "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                     "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"] {
            NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                onChange()
            }
        }
    }

    func sendCommand(_ command: Command) -> Bool {
        sendCommandFn?(command.rawValue, nil) ?? false
    }

    @discardableResult
    func setElapsed(_ seconds: Double) -> Bool {
        guard let f = setElapsedFn else { return false }
        f(seconds)
        return true
    }

    /// Calls `completion` on the main queue.
    func getNowPlaying(_ completion: @escaping (NowPlayingInfo?) -> Void) {
        guard let getInfoFn else { completion(nil); return }
        getInfoFn(DispatchQueue.main) { dict in
            guard let raw = dict as? [String: Any], !raw.isEmpty else { completion(nil); return }
            var info = NowPlayingInfo()
            info.title  = raw["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            info.artist = raw["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            info.album  = raw["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
            info.source = "Now Playing"
            if let data = raw["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
                info.artwork = NSImage(data: data)
            }
            info.artworkKey = (raw["kMRMediaRemoteNowPlayingInfoContentItemIdentifier"] as? String)
                ?? "\(info.artist)\u{1}\(info.title)"
            // Apple Podcasts & friends label spoken-word items here; Spotify doesn't
            // populate it, which is what `attachSpotifyMetadata` covers.
            if let mediaType = raw["kMRMediaRemoteNowPlayingInfoMediaType"] as? String {
                info.isPodcast = mediaType.localizedCaseInsensitiveContains("podcast")
            }
            let rate = (raw["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double) ?? 0
            info.isPlaying = rate > 0
            info.duration = raw["kMRMediaRemoteNowPlayingInfoDuration"] as? Double
            if let elapsed = raw["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double {
                info.elapsed = elapsed
                info.elapsedAt = Date()
            }
            guard info.hasContent else { completion(nil); return }
            if let getPlayingFn = self.getPlayingFn {
                getPlayingFn(DispatchQueue.main) { playing in
                    var i = info; i.isPlaying = playing; completion(i)
                }
            } else {
                completion(info)
            }
        }
    }
}

// MARK: - Spotify desktop app bridge (Apple Events)

enum SpotifyBridge {
    static let bundleID = "com.spotify.client"

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    @discardableResult
    private static func run(_ body: String) -> String? {
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application \"Spotify\"\n\(body)\nend tell")
        let result = script?.executeAndReturnError(&error)
        if let error { NSLog("[Notch] Spotify AppleScript error: \(error)"); return nil }
        return result?.stringValue
    }

    /// Fires the macOS Automation permission prompt for Spotify (used during onboarding).
    static func triggerPermissionPrompt() {
        guard isRunning else { return }
        _ = run("return (player state as text)")
    }

    static func command(_ verb: String) {
        guard isRunning else { return }
        _ = run(verb)
    }

    static func seek(to seconds: Double) {
        guard isRunning else { return }
        _ = run("set player position to \(seconds)")
    }

    /// True for a podcast episode URI ("spotify:episode:xxxx").
    static func isEpisodeURI(_ uri: String) -> Bool { uri.hasPrefix("spotify:episode:") }

    /// "spotify:track:xxxx" → "xxxx"; nil for episodes / local files / anything else.
    static func bareTrackID(_ uri: String) -> String? {
        guard uri.hasPrefix("spotify:track:") else { return nil }
        return String(uri.dropFirst("spotify:track:".count))
    }

    /// Lightweight id+name probe used when MediaRemote (not Apple Events) is the
    /// primary data source but we still want the Spotify track id.
    static func currentTrackIDAndName() -> (id: String, name: String)? {
        guard isRunning else { return nil }
        let body = """
        if player state is stopped then return ""
        return (id of current track) & linefeed & (name of current track)
        """
        guard let out = run(body), !out.isEmpty else { return nil }
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1...].joined(separator: "\n"))
    }

    /// Returns the current track plus an optional artwork URL to fetch asynchronously.
    static func fetch() -> (NowPlayingInfo, URL?)? {
        guard isRunning else { return nil }
        let body = """
        if player state is stopped then return ""
        set t to name of current track
        set a to artist of current track
        set al to album of current track
        set tid to id of current track
        set art to artwork url of current track
        set ps to (player state as text)
        set dur to duration of current track  -- ms
        set pos to player position             -- seconds (Double)
        return t & linefeed & a & linefeed & al & linefeed & tid & linefeed & art & linefeed & ps & linefeed & dur & linefeed & pos
        """
        guard let out = run(body), !out.isEmpty else { return nil }
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 6 else { return nil }
        var info = NowPlayingInfo()
        info.title = parts[0]
        info.artist = parts[1]
        info.album = parts[2]
        info.artworkKey = parts[3].isEmpty ? "\(parts[1])\u{1}\(parts[0])" : parts[3]
        info.spotifyTrackID = bareTrackID(parts[3])
        info.isPodcast = isEpisodeURI(parts[3])
        info.isPlaying = parts[5] == "playing"
        info.source = "Spotify"
        if parts.count >= 8 {
            if let durMs = Double(parts[6]), durMs > 0 { info.duration = durMs / 1000 }
            if let pos = Double(parts[7]) {
                info.elapsed = pos
                info.elapsedAt = Date()
            }
        }
        let artURL = URL(string: parts[4])
        return (info, artURL)
    }
}
