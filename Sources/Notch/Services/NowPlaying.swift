import AppKit
import Combine

struct NowPlayingInfo: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var isPlaying = false
    var artwork: NSImage?
    var artworkKey: String?     // url or track id, so we can avoid re-fetching artwork
    var source = ""             // "Spotify", "Now Playing", …
    var hasContent: Bool { !title.isEmpty }
}

/// Reads & controls whatever is playing. Prefers the system "Now Playing" data
/// (the private MediaRemote framework, same source the Control Center widget uses);
/// falls back to talking to the Spotify desktop app directly via Apple Events when
/// the system data is unavailable (recent macOS locks MediaRemote down for
/// un-entitled apps).
@MainActor
final class NowPlayingManager: ObservableObject {
    @Published private(set) var info = NowPlayingInfo()

    private let mr = MediaRemoteBridge()
    private var pollTimer: Timer?
    private var usingSpotifyFallback = false
    private var artworkCache: [String: NSImage] = [:]

    func start() {
        mr.registerForNotifications { [weak self] in self?.refresh() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func togglePlayPause() { command(.togglePlayPause, spotify: "playpause") }
    func next()            { command(.nextTrack, spotify: "next track") }
    func previous()        { command(.previousTrack, spotify: "previous track") }

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
        }
    }

    private func attachArtwork(_ info: inout NowPlayingInfo) {
        if info.artwork == nil, let key = info.artworkKey, let cached = artworkCache[key] {
            info.artwork = cached
        }
        if let art = info.artwork, let key = info.artworkKey { artworkCache[key] = art }
    }

    private func loadArtwork(from url: URL, key: String?) {
        if let key, artworkCache[key] != nil { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if let key { self.artworkCache[key] = image }
                if self.info.artworkKey == key || self.info.artwork == nil {
                    self.info.artwork = image
                }
            }
        }.resume()
    }
}

// MARK: - MediaRemote (private framework) bridge

final class MediaRemoteBridge {
    enum Command: Int { case play = 0, pause = 1, togglePlayPause = 2, stop = 3, nextTrack = 4, previousTrack = 5 }

    private typealias GetInfoFn     = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void
    private typealias GetPlayingFn  = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (Int, CFDictionary?) -> Bool
    private typealias RegisterFn    = @convention(c) (DispatchQueue) -> Void

    private let getInfoFn: GetInfoFn?
    private let getPlayingFn: GetPlayingFn?
    private let sendCommandFn: SendCommandFn?
    private let registerFn: RegisterFn?

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
            let rate = (raw["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double) ?? 0
            info.isPlaying = rate > 0
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
        return t & linefeed & a & linefeed & al & linefeed & tid & linefeed & art & linefeed & ps
        """
        guard let out = run(body), !out.isEmpty else { return nil }
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 6 else { return nil }
        var info = NowPlayingInfo()
        info.title = parts[0]
        info.artist = parts[1]
        info.album = parts[2]
        info.artworkKey = parts[3].isEmpty ? "\(parts[1])\u{1}\(parts[0])" : parts[3]
        info.isPlaying = parts[5] == "playing"
        info.source = "Spotify"
        let artURL = URL(string: parts[4])
        return (info, artURL)
    }
}
