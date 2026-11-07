import XCTest
import AppKit
import SwiftUI
import Darwin
@testable import Notch

#if NOTCH_BENCHMARK
private enum BenchmarkFailure: Error { case check(String) }

@MainActor
private final class BenchReport {
    let directory: URL
    let samples: Int
    var results: [[String: Any]] = []
    var notes: [String] = []
    var successful = false

    init() throws {
        directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOTCH_BENCHMARK_DIR"] ?? ".build/benchmarks/notch")
        samples = Int(ProcessInfo.processInfo.environment["NOTCH_BENCHMARK_SAMPLES"] ?? "10") ?? 10
        guard (3...1000).contains(samples) else { throw BenchmarkFailure.check("samples must be 3...1000") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func cpuMS() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }

    static func resources() -> [String: Any] {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, size) == size else { return [:] }
        let fdBytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        return ["residentMiB": Double(task.pti_resident_size) / 1_048_576,
                "threads": task.pti_threadnum, "fdCapacityEstimate": Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride]
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1))]
    }

    func measure(_ name: String, iterations: Int? = nil,
                 prepare: () async throws -> Void = {}, operation: () async throws -> Void) async throws {
        var walls: [Double] = [], cpus: [Double] = [], memory: [[String: Any]] = []
        let before = Self.resources()
        do {
            for index in 0..<((iterations ?? samples) + 2) {
                try await prepare()
                let cpu = Self.cpuMS(), start = DispatchTime.now().uptimeNanoseconds
                try await operation()
                let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                let usedCPU = Self.cpuMS() - cpu
                if index >= 2 { walls.append(wall); cpus.append(usedCPU); memory.append(Self.resources()) }
            }
            let p95 = Self.percentile(walls, 0.95)
            results.append(["id": name, "status": "passed", "samples": walls.count,
                            "wallMS": walls, "cpuMS": cpus, "resources": memory, "resourcesBefore": before,
                            "wallP50MS": Self.percentile(walls, 0.5), "wallP95MS": p95,
                            "wallMaxMS": walls.max() ?? 0, "meanCPUMS": cpus.reduce(0, +) / Double(cpus.count)])
            print(String(format: "NOTCH BENCH %@: p95 %.3f ms", name, p95))
        } catch {
            results.append(["id": name, "status": "failed", "error": String(describing: error)])
            throw error
        }
    }

    func write() throws {
        let value: [String: Any] = ["schemaVersion": 1, "successful": successful,
            "timestamp": ISO8601DateFormatter().string(from: Date()), "claude": "excluded",
            "configuration": "release + NOTCH_BENCHMARK fixture accessors", "warmups": 2,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "logicalCPUs": ProcessInfo.processInfo.processorCount, "results": results, "notes": notes]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("notch.json"), options: .atomic)
    }

    func capture(_ area: String, operation: () async throws -> Void) async {
        do { try await operation() }
        catch {
            results.append(["id": area + ".failure", "status": "failed", "error": String(describing: error)])
            print("NOTCH BENCH \(area) failed: \(error)")
        }
    }
}

@MainActor
private final class BenchEnvironment {
    let suite = "NotchBenchmark.\(UUID())"
    let defaults: UserDefaults
    let notch: NotchState
    let settings: SettingsStore
    let music = NowPlayingManager()
    let spotify = SpotifyLibrary()
    let audio = AudioMeter()
    let screenshots: ScreenshotWatcher
    let agents = AgentSessionStore(resolveAncestor: { _, _ in nil }, processes: { _ in [] })
    let cursor = CursorTracker()

    init(directory: URL) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "settings.claudeSessionsEnabled")
        notch = NotchState(defaults: defaults)
        settings = SettingsStore(defaults: defaults)
        screenshots = ScreenshotWatcher(directory: directory)
    }

    func cleanup() {
        screenshots.stop()
        notch.open(tab: .music); notch.close()
        defaults.removePersistentDomain(forName: suite)
    }

    func inject<V: View>(_ view: V) -> some View {
        view.environmentObject(notch).environmentObject(settings).environmentObject(music)
            .environmentObject(spotify).environmentObject(audio).environmentObject(screenshots)
            .environmentObject(agents).environmentObject(cursor)
    }

    func root() -> AnyView {
        let size = ScreenMetrics.screen?.frame.size ?? CGSize(width: 1440, height: 900)
        let frame = ScreenMetrics.windowFrame(for: notch.dock)
        let screen = ScreenMetrics.screen?.frame ?? CGRect(origin: .zero, size: size)
        let origin = CGPoint(x: frame.minX - screen.minX, y: screen.maxY - frame.maxY)
        return AnyView(inject(NotchRootView()).frame(width: size.width, height: size.height)
            .offset(x: -origin.x, y: -origin.y)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading).clipped())
    }
}

@MainActor
private final class BenchHost {
    let window: NSWindow
    let host: NSHostingView<AnyView>
    init(_ view: AnyView, size: CGSize) {
        host = NSHostingView(rootView: view)
        window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        host.frame.size = size
    }
    func draw() throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw BenchmarkFailure.check("Could not allocate hosted render")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
    func close() {
        // Closing an offscreen window alone can leave SwiftUI transactions/tasks alive.
        // Tear down its content explicitly so later measurements do not render old fixtures.
        host.rootView = AnyView(EmptyView())
        window.contentView = nil
        window.close()
    }
}
#endif

@MainActor
final class NotchPerformanceTests: XCTestCase {
    func testWholeAppBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_WHOLE_APP_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt in with scripts/benchmark-notch.sh")
        }
        #if NOTCH_BENCHMARK && !DEBUG
        let report = try BenchReport()
        defer { try? report.write() }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("notch-suite-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let env = BenchEnvironment(directory: temporary)
        defer { env.cleanup() }

        await report.capture("state-settings") { try await self.stateAndSettings(report, env) }
        await report.capture("music-audio") { try await self.musicAndAudio(report, env) }
        await report.capture("spotify") { try await self.spotify(report, env) }
        await report.capture("screenshots") { try await self.screenshots(report, env, temporary) }
        await report.capture("codex") { try await self.codexDelivery(report, env, temporary) }
        await report.capture("logging") { try await self.logging(report, temporary) }
        if ScreenMetrics.screen != nil {
            await report.capture("render") { try await self.views(report, env) }
            await report.capture("mixed") { try await self.mixedSoak(report, env, temporary) }
        } else {
            report.results.append(["id": "views-and-mixed-soak", "status": "blocked", "reason": "No graphical display"])
        }
        report.successful = report.results.allSatisfy { $0["status"] as? String == "passed" }
        try report.write()
        try require(!report.results.contains { $0["status"] as? String == "failed" }, "Benchmark failures; see notch.json")
        #else
        throw XCTSkip("Requires release build with -DNOTCH_BENCHMARK")
        #endif
    }

    #if NOTCH_BENCHMARK
    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw BenchmarkFailure.check(message) }
    }
    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func stateAndSettings(_ report: BenchReport, _ env: BenchEnvironment) async throws {
        try await report.measure("state.transitions-and-docking") {
            for dock in NotchDock.allCases {
                env.notch.dock = dock
                env.notch.isHoverPreview = true
                env.notch.open()
                try self.require(!env.notch.isHoverPreview, "Hover preview remained expanded")
                env.notch.musicPanelExpanded = true
                env.notch.sessionsPanelExpanded = true
                try self.require(!env.notch.musicPanelExpanded, "Overlapping foldouts")
                for rows in [0, 1, 5, 20] {
                    try self.require(env.notch.openBlobSize(sessionRows: rows).height <= ScreenMetrics.windowSize(for: dock).height,
                                     "Session panel exceeds window")
                }
                env.notch.open(tab: .screenshots); env.notch.close()
                try self.require(!env.notch.sessionsPanelExpanded && !env.notch.isOpen, "Close left panel expanded")
                try self.require(NotchDock.load(from: env.defaults) == dock, "Dock not persisted")
                if let screen = ScreenMetrics.screen {
                    let frame = screen.frame
                    let target: CGPoint
                    switch dock {
                    case .top: target = CGPoint(x: frame.midX, y: frame.maxY - 1)
                    case .left: target = CGPoint(x: frame.minX + 1, y: frame.midY)
                    case .right: target = CGPoint(x: frame.maxX - 1, y: frame.midY)
                    }
                    try self.require(NotchDragController.nearestDock(to: target, on: screen) == dock,
                                     "Incorrect drag landing target")
                }
            }
            env.notch.open(tab: .music); env.notch.close()
        }
        try await report.measure("settings.local-roundtrip") {
            env.settings.copyScreenshotToClipboard.toggle()
            env.settings.codexSessionsEnabled.toggle()
            env.settings.podcastSkipSeconds = env.settings.podcastSkipSeconds == 15 ? 30 : 15
            let restored = SettingsStore(defaults: env.defaults)
            try self.require(restored.podcastSkipSeconds == env.settings.podcastSkipSeconds
                             && restored.codexSessionsEnabled == env.settings.codexSessionsEnabled
                             && restored.copyScreenshotToClipboard == env.settings.copyScreenshotToClipboard,
                             "Settings failed to roundtrip")
        }
        var location: String? = "/synthetic/original"
        let routing = ScreenshotRouting(defaults: env.defaults, managedPath: "/synthetic/managed",
                                        read: { location }, write: { location = $0 }, prepareDirectory: {})
        try await report.measure("settings.screenshot-routing-roundtrip") {
            try routing.setEnabled(true); try routing.setEnabled(true); try routing.setEnabled(false)
            try self.require(location == "/synthetic/original", "Routing did not restore original")
        }
        try await report.measure("state.scheduled-close", iterations: 3) {
            env.notch.open(); env.notch.scheduleClose(after: 0.02)
            let deadline = Date().addingTimeInterval(2)
            while env.notch.isOpen && Date() < deadline { try await self.pause(0.002) }
            try self.require(!env.notch.isOpen, "Scheduled close did not fire")
        }
    }

    private func musicAndAudio(_ report: BenchReport, _ env: BenchEnvironment) async throws {
        var info = NowPlayingInfo()
        info.title = String(repeating: "Long title 🎵 ", count: 12)
        info.artist = "Synthetic artist"; info.isPlaying = true
        info.duration = 7200; info.elapsed = 120; info.elapsedAt = Date(); info.playbackRate = 1.5
        try await report.measure("music.metadata-track-switches-100") {
            for n in 0..<100 {
                var next = info; next.title += String(n); next.isPodcast = n % 2 == 0
                env.music.benchmarkReceive(next)
                try self.require(env.music.info.hasContent && env.music.info.liveElapsed >= 120, "Bad playback state")
            }
            env.music.benchmarkReceive(NowPlayingInfo())
            try self.require(env.music.displayArt == nil && env.music.displayKey.isEmpty, "Stale stopped track")
        }
        for rate in [44100.0, 48000.0, 96000.0] {
            for frames in [512, 2048] {
                for silence in [false, true] {
                    env.audio.benchmarkConfigure(sampleRate: rate)
                    var samples = (0..<(frames * 2)).map { n in
                        Float(silence ? 0 : 0.2 * sin(Double(n / 2) * 2 * .pi * 500 / rate))
                    }
                    try await report.measure("audio.\(Int(rate))Hz-\(frames)frames-\(silence ? "silence" : "tone")") {
                        env.audio.benchmarkProcess(&samples, channels: 2)
                        try self.require(env.audio.bars.allSatisfy { $0.isFinite && (0...1).contains($0) }, "Invalid meter output")
                    }
                }
            }
        }
        env.audio.stop()
    }

    private func cache(playlists: Int, tracks: Int) throws -> Data {
        let entries: [[String: Any]] = (0..<playlists).map { p in
            ["id": "p\(p)", "name": "Playlist \(p)", "snapshot": "fixture",
             "trackIDs": (0..<tracks).map { "t\(($0 + p) % (tracks * 2))" }]
        }
        return try JSONSerialization.data(withJSONObject: ["playlists": entries, "likedIDs": ["t0", "t1"]])
    }

    private func spotify(_ report: BenchReport, _ env: BenchEnvironment) async throws {
        for (playlists, tracks) in [(10, 100), (100, 1000)] {
            let data = try cache(playlists: playlists, tracks: tracks)
            try await report.measure("spotify.cache-decode-index-\(playlists * tracks)-memberships") {
                try env.spotify.benchmarkLoadCache(data)
                try self.require(env.spotify.playlistCount == playlists, "Incomplete playlist index")
            }
            try await report.measure("spotify.membership-1000-lookups-\(playlists * tracks)-index") {
                for n in 0..<1000 { env.spotify.trackChanged("t\(n % (tracks * 2))") }
                env.spotify.trackChanged("t0")
                try self.require(env.spotify.membership.liked == true && env.spotify.membership.playlists.contains { $0.id == "p0" },
                                 "Incorrect membership lookup")
                env.spotify.trackChanged(nil)
                try self.require(!env.spotify.membership.hasAny, "Stale membership after clearing track")
            }
        }
    }

    private func png(width: Int, height: Int) throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 160, bitmap.bytesPerRow * height)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw BenchmarkFailure.check("PNG fixture") }
        return data
    }

    private func screenshots(_ report: BenchReport, _ env: BenchEnvironment, _ directory: URL) async throws {
        for count in [0, 100, 1000, 10000] {
            let folder = directory.appendingPathComponent("folder-\(count)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for n in 0..<count {
                let prefix = n % 2 == 0 ? "Screenshot" : "unrelated"
                try Data([0]).write(to: folder.appendingPathComponent("\(prefix)-\(n).png"))
            }
            try await report.measure("screenshots.cold-start-\(count)-files", iterations: min(report.samples, 5)) {
                let cold = ScreenshotWatcher(directory: folder)
                cold.start(); await cold.waitUntilIdle(); cold.stop()
                try self.require(cold.shots.count == min(7, count / 2), "Cold discovery count incorrect")
            }
            let watcher = ScreenshotWatcher(directory: folder)
            defer { watcher.stop() }
            try await report.measure("screenshots.scan-\(count)-files", iterations: min(report.samples, 5)) {
                await watcher.benchmarkScan(initial: true)
                try self.require(watcher.shots.count == min(7, count / 2), "Wrong screenshot filtering/count")
            }
        }
        try await screenshotResponsiveness(report, env, directory)
        let image = try png(width: 3840, height: 2160)
        let url = directory.appendingPathComponent("Screenshot-4k.png")
        try image.write(to: url)
        try await report.measure("screenshots.thumbnail-4k-to-400px") {
            let thumb = await ScreenshotImage.thumbnail(for: url)
            try self.require(thumb != nil && max(thumb!.size.width, thumb!.size.height) <= 400, "Thumbnail missing/oversized")
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try await report.measure("screenshots.clipboard-4k-private-pasteboard", iterations: min(report.samples, 5)) {
            _ = await ScreenshotClipboard.shared.copy(url, pasteboard: board)
            try self.require(board.availableType(from: [.png, .tiff]) != nil, "Clipboard image missing")
        }
        env.screenshots.start()
        await env.screenshots.waitUntilIdle()
        defer { env.screenshots.stop(); env.screenshots.onNewScreenshot = nil }
        var delivered: URL?
        env.screenshots.onNewScreenshot = { delivered = $0 }
        var n = 0
        try await report.measure("screenshots.filesystem-event-delivery", iterations: 3) {
            n += 1; delivered = nil
            let added = directory.appendingPathComponent("Screenshot-new-\(n).png")
            try image.write(to: added)
            let deadline = Date().addingTimeInterval(4)
            while delivered?.resolvingSymlinksInPath().path != added.resolvingSymlinksInPath().path && Date() < deadline {
                try await self.pause(0.005)
            }
            try self.require(delivered?.resolvingSymlinksInPath().path == added.resolvingSymlinksInPath().path,
                             "Screenshot filesystem event missed: expected \(added.path), got \(delivered?.path ?? "nil"), shots \(env.screenshots.shots)")
        }
        let broken = directory.appendingPathComponent("broken.png")
        try Data([0]).write(to: broken)
        let thumb = await ScreenshotImage.thumbnail(for: broken)
        try require(thumb == nil, "Corrupt thumbnail unexpectedly decoded")
    }

    private func screenshotResponsiveness(_ report: BenchReport, _ env: BenchEnvironment, _ directory: URL) async throws {
        let folder = directory.appendingPathComponent("folder-10000")
        let watcher = ScreenshotWatcher(directory: folder)
        let (monitor, writer) = try rollout(directory)
        defer { watcher.stop(); monitor.stop(); try? writer.close(); env.agents.onAttention = nil }
        _ = monitor.scan(); connect(monitor, env)
        let heartbeat = Task { @MainActor () -> [Double] in
            var lateness: [Double] = []
            while !Task.isCancelled {
                let start = DispatchTime.now().uptimeNanoseconds
                do { try await Task.sleep(nanoseconds: 5_000_000) } catch { break }
                lateness.append(max(0, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 - 5))
            }
            return lateness
        }
        defer { heartbeat.cancel() }
        watcher.start()
        var turn = 0
        try await report.measure("screenshots.codex-delivery-during-10000-file-scan", iterations: 5, prepare: {
            turn += 1; env.notch.dismissToast(); try self.appendTurn(writer, turn: turn + 20_000)
        }) {
            monitor.poll()
            let deadline = Date().addingTimeInterval(3)
            while env.notch.toast == nil && Date() < deadline { try await self.pause(0.001) }
            try self.require(env.notch.toast != nil, "Codex delivery blocked by screenshot discovery")
            env.notch.open(tab: .screenshots); env.notch.close()
        }
        await watcher.waitUntilIdle(); heartbeat.cancel()
        let lateness = await heartbeat.value
        try require(!lateness.isEmpty && watcher.shots.count == 7, "Responsiveness workload incomplete")
        report.results.append(["id": "screenshots.main-actor-during-10000-file-scan", "status": "passed",
            "samples": lateness.count, "wakeLatenessMS": lateness,
            "mainActorWakeLatenessP95MS": BenchReport.percentile(lateness, 0.95),
            "mainActorWakeLatenessMaxMS": lateness.max() ?? 0])
        report.notes.append("Screenshot cold-start includes initial scan, watch installation, and race-closing reconciliation. scan-N-files measures cached refresh. The 5 ms heartbeat spans a cold 10K-file scan with concurrent immediate Codex delivery and UI state changes; it is scheduling latency, not compositor FPS.")
    }

    private func rollout(_ directory: URL) throws -> (CodexSessionMonitor, FileHandle) {
        let url = directory.appendingPathComponent("rollout-benchmark.jsonl")
        let meta: [String: Any] = ["type": "session_meta", "payload": ["id": "integrated", "source": "cli", "cwd": directory.path]]
        var bytes = try JSONSerialization.data(withJSONObject: meta); bytes.append(10); try bytes.write(to: url)
        let writer = try FileHandle(forWritingTo: url); try writer.seekToEnd()
        return (CodexSessionMonitor(processes: { [(pid: getpid(), cwd: directory.path)] }, openPaths: { _ in [url.path] }), writer)
    }

    private func appendTurn(_ writer: FileHandle, turn: Int) throws {
        for kind in ["task_started", "task_complete"] {
            let record: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()), "type": "event_msg",
                "payload": ["type": kind, "turn_id": "turn-\(turn)", "last_agent_message": "Synthetic completion"]]
            var bytes = try JSONSerialization.data(withJSONObject: record); bytes.append(10)
            try writer.write(contentsOf: bytes)
        }
    }

    private func connect(_ monitor: CodexSessionMonitor, _ env: BenchEnvironment) {
        monitor.onEvents = { events in
            for event in events {
                env.agents.apply(event.payload, at: event.date, hookParent: nil, provider: .codex, replaying: event.replaying)
            }
        }
        env.agents.onAttention = { session in
            env.notch.presentSessionToast(SessionToast(session: session, kind: .complete))
        }
    }

    private func codexDelivery(_ report: BenchReport, _ env: BenchEnvironment, _ directory: URL) async throws {
        let (monitor, writer) = try rollout(directory)
        defer { try? writer.close(); monitor.stop(); env.agents.onAttention = nil }
        _ = monitor.scan(); connect(monitor, env)
        var turn = 0
        try await report.measure("codex.worker-to-state-to-toast", prepare: {
            turn += 1; env.notch.dismissToast(); try self.appendTurn(writer, turn: turn)
        }) {
            monitor.poll()
            let deadline = Date().addingTimeInterval(3)
            while env.notch.toast == nil && Date() < deadline { try await self.pause(0.001) }
            try self.require(env.agents.sessions.contains { $0.sessionID == "integrated" && $0.state == .done }, "Completion state missing")
            try self.require(env.notch.toast != nil && env.notch.isOpen, "Toast not presented")
        }
        env.notch.open(); env.notch.close()
    }

    private func logging(_ report: BenchReport, _ directory: URL) async throws {
        let log = BoundedLog(url: directory.appendingPathComponent("logs/notch.log"), limit: 8192)
        try await report.measure("logging.100-records-with-rotation") {
            for n in 0..<100 { log.append("benchmark \(n) " + String(repeating: "x", count: 128)) }
            let size = try Data(contentsOf: log.url).count
            try self.require(size <= 8192, "Unbounded log")
        }
    }

    private func views(_ report: BenchReport, _ env: BenchEnvironment) async throws {
        var info = NowPlayingInfo(); info.title = "A deliberately long track title to exercise the marquee 🎵"
        info.artist = "Synthetic artist"; info.duration = 7200; info.elapsed = 130; info.elapsedAt = Date()
        info.spotifyTrackID = "t0"
        env.spotify.trackChanged("t0")
        let imageData = try png(width: 64, height: 64)
        info.artwork = NSImage(data: imageData); info.accentColor = .mint
        let shots = report.directory.appendingPathComponent("renders")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        for dock in NotchDock.allCases {
            env.notch.dock = dock
            for state in ["empty", "collapsed-playing", "hover", "open-music", "podcast", "playlists",
                          "screenshots", "sessions-20", "completion-toast", "screenshot-toast", "overlay-hidden"] {
                for session in env.agents.sessions {
                    env.agents.apply(["session_id": session.sessionID, "hook_event_name": "SessionEnd"],
                                     at: Date(), hookParent: nil, provider: .codex, replaying: true)
                }
                env.notch.open(tab: .music); env.notch.close()
                info.isPlaying = state != "empty"; info.isPodcast = state == "podcast"
                env.music.benchmarkReceive(state == "empty" ? NowPlayingInfo() : info)
                env.notch.isSystemOverlayActive = false
                switch state {
                case "hover": env.notch.isHoverPreview = true
                case "open-music", "podcast": env.notch.open()
                case "playlists": env.notch.open(); env.notch.musicPanelExpanded = true
                case "screenshots": await env.screenshots.benchmarkScan(initial: true); env.notch.open(tab: .screenshots)
                case "sessions-20":
                    for n in 0..<20 {
                        env.agents.apply(["session_id": "render-\(n)", "hook_event_name": "UserPromptSubmit", "cwd": "/synthetic/project"],
                                         at: Date(), hookParent: nil, provider: .codex, replaying: true)
                    }
                    env.notch.open(); env.notch.sessionsPanelExpanded = true
                case "completion-toast":
                    let session = AgentSession(sessionID: "toast", provider: .codex, cwd: "/synthetic/project", lastEventAt: Date(), startedAt: Date())
                    env.notch.presentSessionToast(SessionToast(session: session, kind: .complete))
                case "screenshot-toast": env.notch.presentScreenshotToast(url: URL(fileURLWithPath: "/synthetic/image.png"))
                case "overlay-hidden": env.notch.isSystemOverlayActive = true
                default: break
                }
                let host = BenchHost(env.root(), size: ScreenMetrics.windowSize(for: dock))
                defer { host.close() }
                // Banners intentionally start blank while the notch expands.
                // Capture their visible phase instead of benchmarking that blank lead-in.
                try await pause(state.hasSuffix("toast") ? 1.1 : (state == "screenshots" ? 0.3 : 0.05))
                var last: NSBitmapImageRep?
                try await report.measure("render.\(dock.rawValue).\(state)", iterations: min(report.samples, 5)) {
                    // Invalidate display and perform a synchronous hosted bitmap draw, not a GPU frame measurement.
                    host.host.needsDisplay = true
                    last = try host.draw()
                }
                if let png = last?.representation(using: .png, properties: [:]) {
                    try png.write(to: shots.appendingPathComponent("\(dock.rawValue)-\(state).png"))
                }
            }
        }
        let unavailable = BenchEnvironment(directory: report.directory.appendingPathComponent("missing-screenshot-folder"))
        defer { unavailable.cleanup() }
        unavailable.screenshots.start(); await unavailable.screenshots.waitUntilIdle()
        try require(unavailable.screenshots.issue != nil, "Missing-folder status was not published")
        for dock in NotchDock.allCases {
            unavailable.notch.dock = dock; unavailable.notch.open(tab: .screenshots)
            let errorHost = BenchHost(unavailable.root(), size: ScreenMetrics.windowSize(for: dock))
            defer { errorHost.close() }
            try await pause(0.05)
            let bitmap = try errorHost.draw()
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: shots.appendingPathComponent("\(dock.rawValue)-screenshots-unavailable.png"))
            }
        }
        env.notch.isSystemOverlayActive = false
        let host = BenchHost(AnyView(env.inject(SettingsView())), size: CGSize(width: 480, height: 720))
        defer { host.close() }
        try await report.measure("render.settings", iterations: min(report.samples, 5)) { _ = try host.draw() }
        report.notes.append("Hosted bitmap renders exercise view layout/drawing; screenshots require visual review. They are not compositor frame times or gesture tests.")
    }

    private func mixedSoak(_ report: BenchReport, _ env: BenchEnvironment, _ directory: URL) async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["NOTCH_BENCHMARK_SOAK_SECONDS"] ?? "10") ?? 10
        try require(seconds >= 3 && seconds <= 3600, "Soak duration must be 3...3600 seconds")
        let (monitor, writer) = try rollout(directory)
        defer { try? writer.close(); monitor.stop(); env.agents.onAttention = nil; env.screenshots.stop() }
        _ = monitor.scan(); connect(monitor, env)
        env.notch.dock = .top; env.notch.open()
        env.screenshots.start()
        env.audio.benchmarkConfigure(sampleRate: 48000)
        var samples = (0..<1024).map { Float(0.2 * sin(Double($0 / 2) * 2 * .pi * 500 / 48000)) }
        let host = BenchHost(env.root(), size: ScreenMetrics.windowSize(for: .top))
        defer { host.close() }
        let soakCapture = try png(width: 400, height: 240)
        let before = BenchReport.resources(), start = DispatchTime.now().uptimeNanoseconds, cpu = BenchReport.cpuMS()
        var lateness: [Double] = [], resourceSamples: [[String: Any]] = []
        var ticks = 0, turns = 0
        let interval: UInt64 = 33_333_333
        var due = start + interval
        while Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 < seconds {
            let now = DispatchTime.now().uptimeNanoseconds
            if now < due { try await Task.sleep(nanoseconds: due - now) }
            let arrival = DispatchTime.now().uptimeNanoseconds
            lateness.append(max(0, Double(arrival) - Double(due)) / 1e6)
            ticks += 1
            env.audio.benchmarkProcess(&samples, channels: 2)
            env.cursor.point = CGPoint(x: ticks % 300, y: ticks % 100)
            if ticks % 30 == 0 {
                turns += 1; try appendTurn(writer, turn: turns + 10_000); monitor.poll()
                env.spotify.trackChanged("t\(turns)")
                let url = directory.appendingPathComponent("Screenshot-soak-\(turns).png")
                try soakCapture.write(to: url)
                env.notch.open(tab: turns % 2 == 0 ? .music : .screenshots)
                env.notch.sessionsPanelExpanded = turns % 3 == 0
                resourceSamples.append(BenchReport.resources())
            }
            _ = try host.draw()
            due += interval
            // Record lateness, then drop missed ticks instead of busy-looping to catch up.
            if due < DispatchTime.now().uptimeNanoseconds { due = DispatchTime.now().uptimeNanoseconds + interval }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let usedCPU = BenchReport.cpuMS() - cpu
        try await pause(0.05)
        try require(turns > 0 && env.agents.sessions.contains { $0.sessionID == "integrated" && $0.state == .done }, "Mixed workload missed final completion")
        report.results.append(["id": "mixed.soak", "status": "passed", "durationSeconds": elapsed,
            "ticks": ticks, "turns": turns, "actualOneCoreCPUPercent": usedCPU / (elapsed * 10),
            "mainActorWakeLatenessP95MS": BenchReport.percentile(lateness, 0.95),
            "mainActorWakeLatenessMaxMS": lateness.max() ?? 0, "wakeLatenessMS": lateness,
            "resourcesBefore": before, "resourcesAfter": BenchReport.resources(), "resources": resourceSamples,
            "hostedWindowCount": NSApplication.shared.windows.count])
        report.notes.append("Mixed soak includes 30 Hz forced bitmap captures and synthetic DSP; CPU is measured for this harness, not the shipping app. Wake lateness is not FPS. Short runs do not establish leak freedom.")
    }
    #endif
}
