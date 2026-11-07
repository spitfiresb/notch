import SwiftUI
import ImageIO

/// Helpers for screenshot thumbnails / timestamps.
enum ScreenshotImage {
    private static let thumbnailQueue = DispatchQueue(label: "notch.screenshots.thumbnails", qos: .userInitiated)
    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func relativeTime(_ date: Date?) -> String {
        guard let date else { return "" }
        if -date.timeIntervalSinceNow < 45 { return "just now" }
        return relFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Rasterize the first page without creating an AppKit view or touching the main actor.
    static func pdfImage(_ url: URL, maxPixel: CGFloat = 4096) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { return nil }
        let bounds = page.getBoxRect(.mediaBox)
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let scale = min(2, maxPixel / max(bounds.width, bounds.height))
        let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                     rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    static func thumbnail(for url: URL, maxPixel: CGFloat = 400) async -> NSImage? {
        let token = ScreenshotScanCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                thumbnailQueue.async {
                    let result: NSImage? = autoreleasepool {
                        guard !token.cancelled,
                              let stamp = ScreenshotFileStamp.read(url), stamp.size <= 128 * 1024 * 1024 else { return nil }
                        let cg: CGImage?
                        if url.pathExtension.lowercased() == "pdf" {
                            cg = pdfImage(url, maxPixel: maxPixel)
                        } else {
                            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), ScreenshotScanner.canDecode(src) else { return nil }
                            let opts: [CFString: Any] = [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: maxPixel
                            ]
                            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                        }
                        guard !token.cancelled, let cg else { return nil }
                        return NSImage(cgImage: cg, size: .zero)
                    }
                    continuation.resume(returning: result)
                }
            }
        }, onCancel: { token.cancel() })
    }
}
