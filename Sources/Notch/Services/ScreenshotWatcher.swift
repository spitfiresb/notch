import AppKit
import Combine
import CoreServices

/// Watches the folder macOS saves screenshots into and keeps the most-recent few.
/// Uses a direct filesystem watch on the folder (plus a slow safety-net poll) — no
/// dependency on Spotlight indexing — and identifies screenshots by macOS's naming.
@MainActor
final class ScreenshotWatcher: ObservableObject {
    @Published private(set) var shots: [URL] = []

    /// Called when a screenshot appears *after* the app launched.
    var onNewScreenshot: ((URL) -> Void)?

    private let maxCount = 7
    private let dir: URL
    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var pollTimer: Timer?
    private var rescanWork: DispatchWorkItem?
    private var newestSeen: Date = .distantPast
    private var didInitialScan = false

    init() { dir = ScreenshotWatcher.screenshotDirectory }

    nonisolated static var screenshotDirectory: URL {
        if let raw = CFPreferencesCopyAppValue("location" as CFString,
                                               "com.apple.screencapture" as CFString) as? String,
           !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    /// Turn off macOS's floating screenshot thumbnail (bottom-right preview), so captures
    /// land straight on disk and Notch can take over the "what just happened" feedback.
    /// `screencapture` re-reads this each time, so it takes effect immediately.
    nonisolated static func disableSystemFloatingThumbnail() {
        CFPreferencesSetValue("show-thumbnail" as CFString, kCFBooleanFalse,
                              "com.apple.screencapture" as CFString,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize("com.apple.screencapture" as CFString,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// Copy a just-captured screenshot file onto the general pasteboard so it can be pasted.
    nonisolated static func copyToPasteboard(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        var types: [NSPasteboard.PasteboardType] = [.tiff]
        if url.pathExtension.lowercased() == "png" { types.insert(.png, at: 0) }
        pb.declareTypes(types, owner: nil)
        if url.pathExtension.lowercased() == "png" { pb.setData(data, forType: .png) }
        pb.setData(image.tiffRepresentation, forType: .tiff)
    }

    func start() {
        scan(initial: true)
        startFolderWatch()
        // Safety net: re-scan every few seconds in case a filesystem event is missed
        // (and to pick up access once the user grants the folder permission).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan(initial: false) }
        }
    }

    // MARK: Filesystem watch

    private func startFolderWatch() {
        dirFD = open(dir.path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleRescan() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
        }
        src.resume()
        source = src
    }

    /// Debounce: macOS may still be writing the file when the event fires.
    private func scheduleRescan() {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan(initial: false) }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Scanning

    private func scan(initial requestedInitial: Bool) {
        let fm = FileManager.default
        // If this fails the folder isn't readable yet (permission) — try again on the poll.
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return }

        let dated: [(url: URL, date: Date)] = entries.compactMap { url in
            guard Self.isScreenshot(url),
                  let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            return (url, date)
        }.sorted { $0.date > $1.date }

        let top = Array(dated.prefix(maxCount).map(\.url))
        if top != shots { shots = top }

        let treatAsInitial = requestedInitial || !didInitialScan
        if let newest = dated.first {
            if treatAsInitial {
                newestSeen = newest.date
            } else if newest.date > newestSeen {
                newestSeen = newest.date
                onNewScreenshot?(newest.url)
            }
        }
        didInitialScan = true
    }

    private static func isScreenshot(_ url: URL) -> Bool {
        guard ["png", "jpg", "jpeg", "heic", "tiff", "pdf"].contains(url.pathExtension.lowercased()) else { return false }
        let name = url.lastPathComponent
        // macOS default screenshot names ("Screenshot …" / older "Screen Shot …").
        if name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot") { return true }
        // Fall back to the Spotlight "is a screen capture" flag for localized names.
        if let item = MDItemCreate(nil, url.path as CFString),
           let flag = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool, flag {
            return true
        }
        return false
    }
}
