import AppKit
import CoreServices
import ImageIO

/// Value identity survives renames, but not replacement of a file at the same path.
struct ScreenshotFileStamp: Equatable {
    struct Identity: Hashable { let device: Int32; let inode: UInt64; let birth: Int64; let birthNanos: Int64 }
    let identity: Identity
    let size: Int64
    let modified: Int64
    let modifiedNanos: Int64
    let changed: Int64
    let changedNanos: Int64
    let isDirectory: Bool
    var date: Date { Date(timeIntervalSince1970: Double(modified) + Double(modifiedNanos) / 1e9) }

    static func read(_ url: URL, followSymlinks: Bool = false) -> Self? {
        var s = stat()
        let status = followSymlinks ? stat(url.path, &s) : lstat(url.path, &s)
        guard status == 0,
              (s.st_mode & S_IFMT) == S_IFREG || (s.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return Self(identity: Identity(device: s.st_dev, inode: s.st_ino,
                                       birth: Int64(s.st_birthtimespec.tv_sec), birthNanos: Int64(s.st_birthtimespec.tv_nsec)),
                    size: s.st_size, modified: Int64(s.st_mtimespec.tv_sec), modifiedNanos: Int64(s.st_mtimespec.tv_nsec),
                    changed: Int64(s.st_ctimespec.tv_sec), changedNanos: Int64(s.st_ctimespec.tv_nsec),
                    isDirectory: (s.st_mode & S_IFMT) == S_IFDIR)
    }
}

final class ScreenshotScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

/// Confined to the watcher's serial utility queue. No AppKit or published state here.
final class ScreenshotScanner: @unchecked Sendable {
    struct Record: Equatable { let url: URL; let stamp: ScreenshotFileStamp }
    struct Snapshot {
        var records: [Record] = []
        var capture: URL?
        var retry = false
        var retryDelay: TimeInterval = 0.3
        var error: String?
        var watchFD: Int32 = -1
        var folderIdentity: ScreenshotFileStamp.Identity?
    }
    private struct Cached { let stamp: ScreenshotFileStamp; let matches: Bool; let checked: Date }
    private var cache: [URL: Cached] = [:]
    private var seen: Set<ScreenshotFileStamp.Identity> = []
    private var initialized = false
    private var folderStamp: ScreenshotFileStamp?
    private var lastFullScan = Date.distantPast
    private var lastRecords: [Record] = []
    private var lastRetry = false
    private struct Pending { var record: Record; var attempts = 0 }
    private var pending: [ScreenshotFileStamp.Identity: Pending] = [:]
    private var notificationIdentity: ScreenshotFileStamp.Identity?
    private(set) var classifications = 0
    private let classify: (URL) -> Bool
    private let ready: (URL) -> Bool

    init(classify: @escaping (URL) -> Bool = ScreenshotScanner.isScreenshot,
         ready: @escaping (URL) -> Bool = ScreenshotScanner.isReady) {
        self.classify = classify; self.ready = ready
    }

    func scan(_ directory: URL, force: Bool = true, needsWatch: Bool = false,
              watchedIdentity: ScreenshotFileStamp.Identity? = nil,
              cancellation: ScreenshotScanCancellation = ScreenshotScanCancellation()) -> Snapshot {
        var result = Snapshot()
        guard !cancellation.cancelled else { return result }
        guard let stamp = ScreenshotFileStamp.read(directory, followSymlinks: true), stamp.isDirectory else {
            result.error = "Screenshot folder unavailable. Retrying automatically."; return result
        }
        result.folderIdentity = stamp.identity
        if needsWatch || (watchedIdentity != nil && watchedIdentity != stamp.identity) {
            result.watchFD = open(directory.path, O_EVTONLY)
        }
        if !force, stamp == folderStamp, !lastRetry, Date().timeIntervalSince(lastFullScan) < 60 {
            result.records = lastRecords; return result
        }
        do {
            let entries = try FileManager.default.contentsOfDirectory(at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            var records: [Record] = []
            var nextCache: [URL: Cached] = [:]
            let now = Date()
            for url in entries {
                if cancellation.cancelled { return result }
                guard Self.extensions.contains(url.pathExtension.lowercased()),
                      let file = ScreenshotFileStamp.read(url), !file.isDirectory else { continue }
                let matches: Bool
                if let cached = cache[url], cached.stamp == file,
                   cached.matches || now.timeIntervalSince(cached.checked) < 60 {
                    matches = cached.matches; nextCache[url] = cached
                } else {
                    classifications += 1; matches = classify(url)
                    nextCache[url] = Cached(stamp: file, matches: matches, checked: now)
                }
                if matches { records.append(Record(url: url, stamp: file)) }
            }
            records.sort {
                if $0.stamp.date != $1.stamp.date { return $0.stamp.date > $1.stamp.date }
                return $0.url.lastPathComponent > $1.url.lastPathComponent
            }
            let identities = Set(records.map { $0.stamp.identity })
            // Initial history is silent. A new identity counts even with an equal/older mtime.
            let new = initialized ? records.filter { !seen.contains($0.stamp.identity) } : []
            if let newest = new.first { notificationIdentity = newest.stamp.identity }
            for record in new { pending[record.stamp.identity] = Pending(record: record) }
            pending = pending.filter { identities.contains($0.key) }
            var readyRecords: [Record] = []
            var checks = 0
            func validate(_ record: Record) -> Bool {
                let id = record.stamp.identity
                guard var waiting = pending[id] else { return true }
                if waiting.record.stamp != record.stamp { waiting.attempts = 0 }
                waiting.record = record
                if waiting.attempts < 6 && checks < 7 {
                    waiting.attempts += 1; checks += 1
                    if ready(record.url), ScreenshotFileStamp.read(record.url) == record.stamp {
                        pending.removeValue(forKey: id)
                        if notificationIdentity == id { result.capture = record.url; notificationIdentity = nil }
                        return true
                    }
                }
                pending[id] = waiting
                if waiting.attempts < 6 {
                    let delay = 0.3 * pow(2, Double(max(0, waiting.attempts - 1)))
                    result.retryDelay = result.retry ? min(result.retryDelay, delay) : delay
                    result.retry = true
                }
                return false
            }
            // A newly discovered file may have an old timestamp and fall outside the visible seven.
            if let notification = records.first(where: { $0.stamp.identity == notificationIdentity }) {
                _ = validate(notification)
            }
            for record in records {
                // Don't spend two readiness attempts on the same file in one scan.
                if record.stamp.identity == notificationIdentity && pending[record.stamp.identity] != nil { continue }
                if validate(record) { readyRecords.append(record) }
                if readyRecords.count == 7 { break }
            }
            cache = nextCache; seen = identities; initialized = true
            folderStamp = stamp; lastFullScan = now
            result.records = readyRecords
            lastRecords = result.records; lastRetry = result.retry
        } catch {
            result.error = "Can’t read the screenshot folder. Check folder access, or choose another screenshot location. Retrying automatically."
        }
        return result
    }

    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "pdf"]
    static func isScreenshot(_ url: URL) -> Bool {
        guard extensions.contains(url.pathExtension.lowercased()) else { return false }
        if url.lastPathComponent.hasPrefix("Screenshot") || url.lastPathComponent.hasPrefix("Screen Shot") { return true }
        if let item = MDItemCreate(nil, url.path as CFString),
           let flag = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool { return flag }
        return false
    }

    static func canDecode(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        return width.doubleValue > 0 && height.doubleValue > 0 && width.doubleValue * height.doubleValue <= 100_000_000
    }

    static func isReady(_ url: URL) -> Bool {
        guard let stamp = ScreenshotFileStamp.read(url), stamp.size > 0, stamp.size <= 128 * 1024 * 1024 else { return false }
        if url.pathExtension.lowercased() == "pdf" {
            return CGPDFDocument(url as CFURL)?.page(at: 1) != nil
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              canDecode(src), CGImageSourceGetStatus(src) == .statusComplete,
              CGImageSourceGetStatusAtIndex(src, 0) == .statusComplete else { return false }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) != nil
    }
}
