import AppKit
import Combine

/// Filesystem-driven screenshot discovery. Main actor only schedules and publishes;
/// enumeration, Spotlight metadata, stat calls and readiness checks run on a utility queue.
@MainActor
final class ScreenshotWatcher: ObservableObject {
    @Published private(set) var shots: [URL] = []
    @Published private(set) var records: [ScreenshotScanner.Record] = []
    @Published private(set) var issue: String?
    @Published private(set) var isRefreshing = false
    var onNewScreenshot: ((URL) -> Void)?
    var onReset: (() -> Void)?

    private let queue = DispatchQueue(label: "notch.screenshots.scan", qos: .utility)
    private let directoryProvider: () -> URL
    private let scannerFactory: () -> ScreenshotScanner
    private var scanner: ScreenshotScanner
    private var dir: URL
    private var source: DispatchSourceFileSystemObject?
    private var watchedIdentity: ScreenshotFileStamp.Identity?
    private var recoveryWork: DispatchWorkItem?
    private var rescanWork: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?
    private var cancellation = ScreenshotScanCancellation()
    private var generation = 0
    private var running = false
    private var inFlight = false
    private var dirty = false
    private var forceNext = false
    private var retryDelay: TimeInterval = 1
    private(set) var completedScans = 0

    init(directory: URL? = nil, directoryProvider: (() -> URL)? = nil,
         scannerFactory: @escaping () -> ScreenshotScanner = { ScreenshotScanner() }) {
        let provider = directoryProvider ?? { directory ?? ScreenshotWatcher.screenshotDirectory }
        self.directoryProvider = provider; dir = provider()
        self.scannerFactory = scannerFactory; scanner = scannerFactory()
    }

    nonisolated static var screenshotDirectory: URL {
        if let raw = CFPreferencesCopyAppValue("location" as CFString,
                                               "com.apple.screencapture" as CFString) as? String, !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    func start() {
        stop(); running = true; dir = directoryProvider(); scanner = scannerFactory()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        requestScan(force: true)
    }

    func stop() {
        running = false; generation += 1; cancellation.cancel()
        source?.cancel(); source = nil
        recoveryWork?.cancel(); recoveryWork = nil
        rescanWork?.cancel(); rescanWork = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil; dirty = false; forceNext = false; isRefreshing = false
        onReset?()
    }

    deinit {
        cancellation.cancel(); source?.cancel(); recoveryWork?.cancel(); rescanWork?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func rebindToCurrentDirectory() {
        let next = directoryProvider()
        guard next != dir else { return }
        generation += 1; cancellation.cancel(); source?.cancel(); source = nil
        rescanWork?.cancel(); rescanWork = nil
        dir = next; scanner = scannerFactory(); retryDelay = 1
        shots = []; records = []; issue = nil; onReset?()
        requestScan(force: true)
    }

    /// Manual retry and wake recovery also pick up changes made in macOS's screenshot toolbar.
    func refresh() {
        guard running else { return }
        rebindToCurrentDirectory(); requestScan(force: true)
    }

    func waitUntilIdle() async {
        while inFlight || dirty { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    private func requestScan(force: Bool) {
        guard running else { return }
        dirty = true; forceNext = forceNext || force
        guard !inFlight else { return }
        dirty = false; inFlight = true; isRefreshing = true
        let force = forceNext; forceNext = false
        let currentGeneration = generation, directory = dir, worker = scanner, needsWatch = source == nil
        let token = ScreenshotScanCancellation(); cancellation = token
        let watchedIdentity = self.watchedIdentity
        queue.async { [weak self] in
            let result = autoreleasepool { worker.scan(directory, force: force, needsWatch: needsWatch, watchedIdentity: watchedIdentity, cancellation: token) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { if result.watchFD >= 0 { close(result.watchFD) }; return }
                self.inFlight = false; self.completedScans += 1
                guard self.running, self.generation == currentGeneration else {
                    if result.watchFD >= 0 { close(result.watchFD) }
                    if self.dirty { self.requestScan(force: self.forceNext) }
                    return
                }
                self.isRefreshing = false; self.issue = result.error
                if result.error == nil {
                    if self.records != result.records { self.records = result.records }
                    let urls = result.records.map(\.url)
                    if self.shots != urls { self.shots = urls }
                }
                if result.watchFD >= 0 {
                    self.watchedIdentity = result.folderIdentity
                    self.installWatch(fd: result.watchFD)
                }
                if let capture = result.capture { self.onNewScreenshot?(capture) }
                let delay: TimeInterval
                if result.error != nil {
                    delay = self.retryDelay; self.retryDelay = min(30, self.retryDelay * 2)
                } else { self.retryDelay = 1; delay = result.retry ? result.retryDelay : 30 }
                self.scheduleRecovery(after: delay, force: result.retry)
                if self.dirty { self.requestScan(force: self.forceNext) }
            }
        }
    }

    private func installWatch(fd: Int32) {
        source?.cancel()
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .revoke], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src, self.source === src else { return }
            if !src.data.intersection([.rename, .delete, .revoke]).isEmpty {
                self.source?.cancel(); self.source = nil
            }
            self.scheduleRescan()
        }
        src.setCancelHandler { close(fd) }
        source = src; src.resume()
        // Watch installation follows enumeration. Reconcile once to close that race.
        dirty = true; forceNext = true
    }

    private func scheduleRescan() {
        guard rescanWork == nil else { return } // bounded debounce: continuous writes cannot starve delivery
        let work = DispatchWorkItem { [weak self] in
            self?.rescanWork = nil; self?.requestScan(force: true)
        }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func scheduleRecovery(after delay: TimeInterval, force: Bool) {
        recoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.rebindToCurrentDirectory(); self.requestScan(force: force)
        }
        recoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
