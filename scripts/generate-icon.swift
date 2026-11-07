import AppKit

// Original vector artwork, rasterized at each icon size. No external assets.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        // White tile on the standard macOS 824/1024 grid.
        let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
        NSGradient(starting: NSColor(white: 1, alpha: 1),
                   ending: NSColor(red: 0.933, green: 0.941, blue: 0.953, alpha: 1))!.draw(in: tile, angle: -90)
        // One black rounded rectangle, centred, in MacBook-notch proportions.
        NSColor(red: 0.043, green: 0.047, blue: 0.059, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 512 - 270, y: 512 - 95, width: 540, height: 190),
                     xRadius: 56, yRadius: 56).fill()
        // Hairline edge so the white tile doesn't disappear on light backgrounds.
        let edge = NSBezierPath(roundedRect: NSRect(x: 100.5, y: 100.5, width: 823, height: 823), xRadius: 184.5, yRadius: 184.5)
        edge.lineWidth = 2
        NSColor(white: 0, alpha: 0.08).setStroke()
        edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!
            .write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
