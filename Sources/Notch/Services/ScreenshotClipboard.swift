import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One conversion in flight and at most one waiting request. New intent supersedes old work.
@MainActor
final class ScreenshotClipboard {
    enum Outcome: Equatable { case copied, failed, superseded, clipboardChanged }
    struct Payload { let png: Data?; let tiff: Data }
    static let shared = ScreenshotClipboard()
    // The worker reads only url; pasteboard, validation and completion stay on the main actor.
    private struct Request: @unchecked Sendable {
        let id: Int
        let url: URL
        let pasteboard: NSPasteboard
        let changeCount: Int
        let canCommit: () -> Bool
        let completion: (Outcome) -> Void
    }
    private let queue = DispatchQueue(label: "notch.screenshots.clipboard", qos: .userInitiated)
    private let prepare: (URL) -> Payload?
    private var serial = 0
    private var busy = false
    private var pending: Request?

    init(prepare: @escaping (URL) -> Payload? = ScreenshotClipboard.prepareImage) { self.prepare = prepare }

    func cancel() {
        serial += 1
        let previous = pending; pending = nil; previous?.completion(.superseded)
    }

    func copy(_ url: URL, pasteboard: NSPasteboard = .general,
              canCommit: @escaping () -> Bool = { true }, completion: @escaping (Outcome) -> Void = { _ in }) {
        serial += 1
        let previous = pending
        pending = Request(id: serial, url: url, pasteboard: pasteboard, changeCount: pasteboard.changeCount,
                          canCommit: canCommit, completion: completion)
        previous?.completion(.superseded)
        launchNext()
    }

    func copy(_ url: URL, pasteboard: NSPasteboard) async -> Outcome {
        await withCheckedContinuation { continuation in
            copy(url, pasteboard: pasteboard, completion: { continuation.resume(returning: $0) })
        }
    }

    private func launchNext() {
        guard !busy, let request = pending else { return }
        pending = nil; busy = true
        let prepare = self.prepare
        queue.async { [weak self] in
            let payload = autoreleasepool { prepare(request.url) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { request.completion(.superseded); return }
                let outcome: Outcome
                if request.id != self.serial || !request.canCommit() { outcome = .superseded }
                else if request.pasteboard.changeCount != request.changeCount { outcome = .clipboardChanged }
                else if let payload {
                    // All expensive decoding/encoding has completed before touching the clipboard.
                    let item = NSPasteboardItem()
                    if let png = payload.png { item.setData(png, forType: .png) }
                    item.setData(payload.tiff, forType: .tiff)
                    request.pasteboard.clearContents()
                    outcome = request.pasteboard.writeObjects([item]) ? .copied : .failed
                } else { outcome = .failed }
                self.busy = false; request.completion(outcome); self.launchNext()
            }
        }
    }

    nonisolated static func prepareImage(_ url: URL) -> Payload? {
        // Bounds cover large multi-display captures while refusing pathological allocations.
        guard let before = ScreenshotFileStamp.read(url), !before.isDirectory,
              before.size > 0, before.size <= 128 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let image: CGImage
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = ScreenshotImage.pdfImage(url) else { return nil }
            image = pdf
        } else {
            guard let source,
                  CGImageSourceGetStatus(source) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue * height.doubleValue <= 100_000_000,
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  ScreenshotFileStamp.read(url) == before else { return nil }
            image = decoded
        }
        guard ScreenshotFileStamp.read(url) == before else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let isPNG = source.map { (CGImageSourceGetType($0) as String?) == UTType.png.identifier } ?? false
        return Payload(png: isPNG ? data : nil, tiff: output as Data)
    }
}

/// Cleanup operates on the confirmed snapshot, and refuses to trash files replaced since confirmation.
enum ScreenshotCleanup {
    struct Item { let url: URL; let stamp: ScreenshotFileStamp }
    static func candidates(in directory: URL) async throws -> [Item] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let entries = try FileManager.default.contentsOfDirectory(at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: nil,
                                                                              options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
                    let items = entries.compactMap { url -> Item? in
                        guard ScreenshotScanner.extensions.contains(url.pathExtension.lowercased()),
                              let stamp = ScreenshotFileStamp.read(url), !stamp.isDirectory,
                              ScreenshotScanner.isScreenshot(url) else { return nil }
                        return Item(url: url, stamp: stamp)
                    }
                    continuation.resume(returning: items)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    static func trash(_ items: [Item], move: @escaping (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) async -> Int {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var count = 0
                for item in items where ScreenshotFileStamp.read(item.url) == item.stamp {
                    do { try move(item.url); count += 1 } catch { /* report aggregate failures to the caller */ }
                }
                continuation.resume(returning: count)
            }
        }
    }
}
