import Foundation

/// NSLog from this SwiftPM executable doesn't reach the unified log on macOS 26,
/// so debug breadcrumbs go to a flat file instead. `tail -f /tmp/notch.log` to follow.
func notchLog(_ msg: String) {
    let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = "/tmp/notch.log"
    let fm = FileManager.default
    if !fm.fileExists(atPath: path) {
        fm.createFile(atPath: path, contents: nil)
    }
    if let fh = FileHandle(forWritingAtPath: path) {
        defer { try? fh.close() }
        try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
    }
}
