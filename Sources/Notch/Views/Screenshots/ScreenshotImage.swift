import SwiftUI
import ImageIO

/// Helpers for screenshot thumbnails / timestamps.
enum ScreenshotImage {
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

    static func thumbnail(for url: URL, maxPixel: CGFloat = 400) async -> NSImage? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { cont.resume(returning: nil); return }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: NSImage(cgImage: cg, size: .zero))
            }
        }
    }
}
