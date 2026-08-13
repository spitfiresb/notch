import AppKit
import Combine
import CryptoKit
import Network
import Security
import SwiftUI

/// Talks to the Spotify Web API to answer "is this song Liked, and which of my
/// playlists is it in?" — the one thing the desktop app shows but no local API
/// exposes. Auth is Authorization-Code-with-PKCE (no client secret); the login
/// redirect is caught by a one-shot loopback HTTP server. Playlist contents are
/// mirrored into a local index (Application Support) and kept fresh cheaply via
/// each playlist's `snapshot_id`, so the per-track lookup is instant and offline.
@MainActor
final class SpotifyLibrary: ObservableObject {
    static let clientID = "0660987f9ffe42c8bfd78a6325a15ebf"
    static let redirectURI = "http://127.0.0.1:8888/callback"
    static let loopbackPort: UInt16 = 8888
    static let scopes = "user-library-read user-library-modify playlist-read-private playlist-read-collaborative playlist-modify-public playlist-modify-private"
    /// Bump when `scopes` grows — tokens granted under an older consent lack the
    /// new scopes, so the user is dropped to "Connect" for a fresh login.
    private static let scopeVersion = 2
    private static let scopeVersionKey = "spotify.scopeVersion"

    enum ConnectionState: Equatable { case disconnected, connecting, connected }

    struct PlaylistRef: Equatable, Identifiable {
        let id: String
        let name: String
        let image: String?      // smallest cover-art URL Spotify offers
    }

    /// What we know about the current track's place in the user's library.
    struct Membership: Equatable {
        var trackID: String?
        var liked: Bool?              // nil = unknown / not fetched yet
        var playlists: [PlaylistRef] = []
        var hasAny: Bool { liked == true || !playlists.isEmpty }
    }

    @Published private(set) var state: ConnectionState = .disconnected
    /// Set when the API refuses us (403) — usually a Development-mode app being
    /// used by a Spotify account that isn't allowlisted. Cleared on any success.
    @Published private(set) var accessDenied = false
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var playlistCount = 0
    @Published private(set) var membership = Membership()
    /// Every writable playlist, index order (roughly most-recent-first from Spotify).
    @Published private(set) var allPlaylists: [PlaylistRef] = []

    private struct PlaylistEntry: Codable {
        let id: String
        let name: String
        var snapshot: String
        let image: String?
        /// When we last saw this playlist change (snapshot flip or our own
        /// write) — the API has no real modified-date, so this proxy drives the
        /// "recently updated" ordering and gets truer over time.
        var updatedAt: Date?
        var trackIDs: [String]
    }
    private struct CacheFile: Codable {
        var userID: String?
        var playlists: [PlaylistEntry] = []
        var likedIDs: [String] = []
        var lastSync: Date?
    }

    private var cache = CacheFile()
    /// trackID → playlists containing it, rebuilt from `cache`.
    private var trackToPlaylists: [String: [PlaylistRef]] = [:]
    private var likedSet: Set<String> = []

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var loopback: LoopbackServer?
    private var loginTimeout: DispatchWorkItem?

    private enum SpotifyError: Error { case notConnected, http(Int, String), badCallback }

    // MARK: - Lifecycle

    func start() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let decoded = try? JSONDecoder().decode(CacheFile.self, from: data) {
            cache = decoded
            lastSync = decoded.lastSync
            rebuildLookup()
        }
        if Keychain.load(account: Keychain.refreshAccount) != nil {
            if UserDefaults.standard.integer(forKey: Self.scopeVersionKey) < Self.scopeVersion {
                notchLog("spotify: scopes grew since last consent — requiring a fresh login")
                disconnect()
                return
            }
            state = .connected
            Task { await sync() }
        } else {
            notchLog("spotify: no refresh token in keychain (status \(Keychain.lastStatus)) — staying disconnected")
        }
    }

    func disconnect() {
        Keychain.delete(account: Keychain.refreshAccount)
        try? FileManager.default.removeItem(at: Self.cacheURL)
        accessToken = nil
        accessExpiry = .distantPast
        accessDenied = false
        cache = CacheFile()
        likedSet = []
        trackToPlaylists = [:]
        playlistCount = 0
        lastSync = nil
        state = .disconnected
        let id = membership.trackID
        membership = Membership(trackID: id)
    }

    // MARK: - OAuth (PKCE + loopback redirect)

    /// Safe to call again mid-login — a previous stalled attempt (closed browser
    /// tab, bad redirect config) is torn down and a fresh one starts.
    func connect() {
        loginTimeout?.cancel(); loginTimeout = nil
        state = .connecting
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL()
        let stateParam = Self.randomURLSafe(24)

        loopback?.stop()
        loopback = LoopbackServer(port: Self.loopbackPort) { [weak self] code, returnedState, error in
            Task { @MainActor in
                self?.handleCallback(code: code, returnedState: returnedState, error: error,
                                     expectedState: stateParam, verifier: verifier)
            }
        }
        guard loopback != nil else {
            notchLog("spotify: couldn't open loopback port \(Self.loopbackPort)")
            state = .disconnected
            return
        }

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: stateParam),
        ]
        NSWorkspace.shared.open(comps.url!)

        loginTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .connecting else { return }
            self.loopback?.stop(); self.loopback = nil
            self.state = .disconnected
        }
        loginTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
    }

    private func handleCallback(code: String?, returnedState: String?, error: String?,
                                expectedState: String, verifier: String) {
        loginTimeout?.cancel(); loginTimeout = nil
        loopback?.stop(); loopback = nil
        guard error == nil, let code, returnedState == expectedState else {
            notchLog("spotify: login failed or denied (\(error ?? "state mismatch"))")
            state = .disconnected
            return
        }
        Task {
            do {
                let token = try await tokenRequest(form: [
                    "grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": Self.redirectURI,
                    "client_id": Self.clientID,
                    "code_verifier": verifier,
                ])
                accessToken = token.access_token
                accessExpiry = Date().addingTimeInterval(token.expires_in - 30)
                if let refresh = token.refresh_token { Keychain.save(refresh, account: Keychain.refreshAccount) }
                UserDefaults.standard.set(Self.scopeVersion, forKey: Self.scopeVersionKey)
                state = .connected
                await sync(force: true)
            } catch {
                notchLog("spotify: token exchange failed: \(error)")
                state = .disconnected
            }
        }
    }

    // MARK: - Current track

    /// Called whenever the now-playing Spotify track changes (or goes away).
    /// Purely a local index lookup — Spotify blocks the per-track `contains`
    /// endpoint for new apps, so Liked Songs is mirrored locally like a playlist.
    func trackChanged(_ trackID: String?) {
        membership = Membership(trackID: trackID,
                                liked: trackID.map { likedSet.contains($0) },
                                playlists: trackID.flatMap { trackToPlaylists[$0] } ?? [])
        // Opportunistic staleness check so the index tracks library edits.
        if state == .connected, trackID != nil { Task { await sync() } }
    }

    // MARK: - Writes (Liked Songs / playlist membership)

    /// Save or unsave the current track to Liked Songs. Optimistic — the UI flips
    /// immediately, and flips back if Spotify rejects the write.
    func setLiked(_ liked: Bool) {
        guard state == .connected, let id = membership.trackID else { return }
        applyLiked(id, liked)
        Task {
            do {
                _ = try await api(liked ? "PUT" : "DELETE",
                                  "https://api.spotify.com/v1/me/library?uris=spotify:track:\(id)")
            } catch {
                notchLog("spotify: like write failed: \(error)")
                applyLiked(id, !liked)
            }
        }
    }

    private func applyLiked(_ id: String, _ liked: Bool) {
        if liked {
            likedSet.insert(id)
            if !cache.likedIDs.contains(id) { cache.likedIDs.insert(id, at: 0) }
        } else {
            likedSet.remove(id)
            cache.likedIDs.removeAll { $0 == id }
        }
        saveCache()
        if membership.trackID == id { membership.liked = liked }
    }

    /// Remove the current track from one of the user's playlists. Optimistic,
    /// with the row restored if the write fails.
    func removeFromPlaylist(_ playlist: PlaylistRef) {
        writePlaylistMembership(playlist, present: false)
    }

    /// Add the current track to one of the user's playlists.
    func addToPlaylist(_ playlist: PlaylistRef) {
        writePlaylistMembership(playlist, present: true)
    }

    private func writePlaylistMembership(_ playlist: PlaylistRef, present: Bool) {
        guard state == .connected, let id = membership.trackID else { return }
        applyPlaylistMembership(playlist, trackID: id, present: present)
        Task {
            let url = "https://api.spotify.com/v1/playlists/\(playlist.id)/items"
            do {
                let data: Data
                if present {
                    data = try await api("POST", "\(url)?uris=spotify:track:\(id)")
                } else {
                    // DELETE ignores the `uris` query (400 "No uris provided") —
                    // it only takes the classic-style JSON body, renamed to `items`.
                    let body = try JSONEncoder().encode(["items": [["uri": "spotify:track:\(id)"]]])
                    data = try await api("DELETE", url, body: body)
                }
                // Adopt the snapshot our own write produced, so the next sync
                // doesn't refetch the whole playlist just to observe it.
                struct Response: Decodable { let snapshot_id: String? }
                if let snap = (try? JSONDecoder().decode(Response.self, from: data))?.snapshot_id,
                   let idx = cache.playlists.firstIndex(where: { $0.id == playlist.id }) {
                    cache.playlists[idx].snapshot = snap
                    saveCache()
                }
            } catch {
                notchLog("spotify: playlist \(present ? "add" : "remove") failed: \(error)")
                applyPlaylistMembership(playlist, trackID: id, present: !present)
            }
        }
    }

    private func applyPlaylistMembership(_ playlist: PlaylistRef, trackID: String, present: Bool) {
        guard let idx = cache.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        if present {
            guard !cache.playlists[idx].trackIDs.contains(trackID) else { return }
            cache.playlists[idx].trackIDs.append(trackID)
        } else {
            cache.playlists[idx].trackIDs.removeAll { $0 == trackID }
        }
        cache.playlists[idx].updatedAt = Date()
        rebuildLookup()
        saveCache()
        if membership.trackID == trackID {
            membership.playlists.removeAll { $0.id == playlist.id }
            if present { membership.playlists.append(playlist) }
        }
    }

    // MARK: - Playlist index sync

    /// Refresh the playlist index. Cheap when nothing changed — playlists whose
    /// `snapshot_id` matches the cache aren't re-fetched.
    func sync(force: Bool = false) async {
        guard state == .connected, !isSyncing else { return }
        if !force, let last = lastSync, Date().timeIntervalSince(last) < 600 { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let me = try await currentUserID()
            var metas: [PlaylistMeta] = []
            var next: String? = "https://api.spotify.com/v1/me/playlists?limit=50"
            while let url = next {
                let page = try JSONDecoder().decode(Page<PlaylistMeta>.self, from: await api("GET", url))
                metas += page.items.compactMap { $0 }
                next = page.next
            }
            // Only playlists the user can actually save into — matches Spotify's
            // own "Saved in" list and keeps the sync small.
            let mine = metas.filter { $0.owner.id == me || $0.collaborative }
            let old = Dictionary(cache.playlists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var fresh: [PlaylistEntry] = []
            for meta in mine {
                if let cached = old[meta.id], cached.snapshot == meta.snapshot_id {
                    // Unchanged contents — keep the track list, refresh the
                    // cosmetic fields (rename, new cover art).
                    fresh.append(PlaylistEntry(id: meta.id, name: meta.name, snapshot: meta.snapshot_id,
                                               image: meta.smallestImage, updatedAt: cached.updatedAt,
                                               trackIDs: cached.trackIDs))
                    continue
                }
                // New-tier apps get 403 on the classic `/playlists/{id}/tracks`;
                // its replacement is `/playlists/{id}/items` with `item` instead
                // of `track` on each row. Same paging contract.
                var ids: [String] = []
                var tNext: String? = "https://api.spotify.com/v1/playlists/\(meta.id)/items?limit=100"
                while let url = tNext {
                    let page = try JSONDecoder().decode(Page<PlaylistRow>.self, from: await api("GET", url))
                    ids += page.items.compactMap { $0?.item?.id }
                    tNext = page.next
                }
                // A changed snapshot means someone touched this playlist since
                // last sync — that's our "recently updated" signal. First-ever
                // sync leaves updatedAt nil so the library order holds until
                // real activity sorts things.
                fresh.append(PlaylistEntry(id: meta.id, name: meta.name, snapshot: meta.snapshot_id,
                                           image: meta.smallestImage,
                                           updatedAt: old[meta.id] == nil ? nil : Date(),
                                           trackIDs: ids))
            }
            cache.playlists = fresh

            // Liked Songs — mirrored in full via /me/tracks (50 per page).
            var likedIDs: [String] = []
            var lNext: String? = "https://api.spotify.com/v1/me/tracks?limit=50"
            while let url = lNext {
                let page = try JSONDecoder().decode(Page<TrackItem>.self, from: await api("GET", url))
                likedIDs += page.items.compactMap { $0?.track?.id }
                lNext = page.next
            }
            cache.likedIDs = likedIDs
            cache.lastSync = Date()
            lastSync = cache.lastSync
            rebuildLookup()
            saveCache()
            // Refresh the current track's row list with the new index.
            trackChanged(membership.trackID)
            notchLog("spotify: synced \(fresh.count) playlists")
        } catch {
            notchLog("spotify: sync failed: \(error)")
        }
    }

    private func currentUserID() async throws -> String {
        if let id = cache.userID { return id }
        struct Me: Decodable { let id: String }
        let me = try JSONDecoder().decode(Me.self, from: await api("GET", "https://api.spotify.com/v1/me"))
        cache.userID = me.id
        return me.id
    }

    private func rebuildLookup() {
        var map: [String: [PlaylistRef]] = [:]
        for p in cache.playlists {
            let ref = PlaylistRef(id: p.id, name: p.name, image: p.image)
            for t in p.trackIDs { map[t, default: []].append(ref) }
        }
        trackToPlaylists = map
        likedSet = Set(cache.likedIDs)
        playlistCount = cache.playlists.count
        // Recently-updated first (Spotify-dialog order); untouched playlists
        // keep their library order after the active ones.
        allPlaylists = cache.playlists.enumerated()
            .sorted { a, b in
                let da = a.element.updatedAt ?? .distantPast
                let db = b.element.updatedAt ?? .distantPast
                return da != db ? da > db : a.offset < b.offset
            }
            .map { PlaylistRef(id: $0.element.id, name: $0.element.name, image: $0.element.image) }
    }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spotify-library.json")
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    // MARK: - HTTP plumbing

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
    }
    private struct Page<T: Decodable>: Decodable {
        let items: [T?]      // Spotify occasionally returns null entries
        let next: String?
    }
    private struct PlaylistMeta: Decodable {
        let id: String
        let name: String
        let snapshot_id: String
        let collaborative: Bool
        let owner: Owner
        let images: [Image]?
        struct Owner: Decodable { let id: String }
        struct Image: Decodable { let url: String }
        /// Spotify lists sizes largest-first; the last is the smallest.
        var smallestImage: String? { images?.last?.url }
    }
    private struct TrackRef: Decodable { let id: String? }   // id null for local files
    /// `/me/tracks` row (classic shape).
    private struct TrackItem: Decodable { let track: TrackRef? }
    /// `/playlists/{id}/items` row (new-tier shape).
    private struct PlaylistRow: Decodable { let item: TrackRef? }

    private func validToken() async throws -> String {
        if let t = accessToken, accessExpiry > Date() { return t }
        guard let refresh = Keychain.load(account: Keychain.refreshAccount) else {
            throw SpotifyError.notConnected
        }
        do {
            let token = try await tokenRequest(form: [
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": Self.clientID,
            ])
            accessToken = token.access_token
            accessExpiry = Date().addingTimeInterval(token.expires_in - 30)
            if let newRefresh = token.refresh_token { Keychain.save(newRefresh, account: Keychain.refreshAccount) }
            return token.access_token
        } catch SpotifyError.http(let code, _) where code == 400 || code == 401 {
            // Refresh token revoked/expired — force a clean re-connect.
            disconnect()
            throw SpotifyError.notConnected
        }
    }

    private func api(_ method: String, _ urlString: String, body: Data? = nil) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            let token = try await validToken()
            var req = URLRequest(url: URL(string: urlString)!)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            notchLog("spotify: \(method) \(urlString) -> \(code) tok=\(token.prefix(10))…")
            if code == 403 { accessDenied = true }
            switch code {
            case 200...299:
                accessDenied = false
                return data
            case 401 where attempt == 1:
                accessToken = nil          // stale — refresh and retry once
            case 429 where attempt <= 3:
                let wait = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1
                try await Task.sleep(nanoseconds: UInt64((wait + 0.2) * 1_000_000_000))
            default:
                throw SpotifyError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    private func tokenRequest(form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(form).data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw SpotifyError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    private static func randomURLSafe(_ length: Int) -> String {
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in charset.randomElement()! })
    }
}

private extension Data {
    func base64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback redirect catcher

/// Minimal one-shot HTTP server on 127.0.0.1 that waits for Spotify's login
/// redirect, hands the `code`/`state` back, and shows a "you can close this tab"
/// page. Ignores stray requests (favicon etc.) and keeps listening until the
/// callback arrives or `stop()` is called.
private final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private let onCallback: (String?, String?, String?) -> Void   // code, state, error

    init?(port: UInt16, onCallback: @escaping (String?, String?, String?) -> Void) {
        self.onCallback = onCallback
        guard let p = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: .tcp, on: p) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            self?.receive(on: conn)
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(on conn: NWConnection, buffered: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, _ in
            guard let self else { conn.cancel(); return }
            var buf = buffered
            if let data { buf += data }
            if let range = buf.range(of: Data("\r\n".utf8)) {
                let requestLine = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                self.handle(requestLine: requestLine, conn: conn)
            } else if done || buf.count > 8192 {
                conn.cancel()
            } else {
                self.receive(on: conn, buffered: buf)
            }
        }
    }

    private func handle(requestLine: String, conn: NWConnection) {
        // "GET /callback?code=...&state=... HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : ""
        guard target.hasPrefix("/callback"),
              let comps = URLComponents(string: "http://127.0.0.1\(target)") else {
            respond(conn, status: "404 Not Found", body: "")
            return
        }
        let q = { (name: String) in comps.queryItems?.first(where: { $0.name == name })?.value }
        let html = """
        <html><head><title>Notch</title></head>
        <body style="background:#111;color:#eee;font-family:-apple-system,sans-serif;\
        display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
        <div style="text-align:center"><h2>Spotify connected to Notch</h2>
        <p>You can close this tab and go back to your Mac.</p></div></body></html>
        """
        respond(conn, status: "200 OK", body: html)
        onCallback(q("code"), q("state"), q("error"))
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n" +
                       "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - Keychain

/// Just enough Keychain to hold the Spotify refresh token.
private enum Keychain {
    static let service = "Notch.Spotify"
    static let refreshAccount = "refresh-token"

    static func save(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    /// OSStatus of the most recent `load` — surfaced in logs to distinguish
    /// "item missing" from "access denied to this (re-signed) binary".
    static var lastStatus: OSStatus = errSecSuccess

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        lastStatus = SecItemCopyMatching(query as CFDictionary, &item)
        guard lastStatus == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
