import Foundation

/// NSLog from this SwiftPM executable doesn't reach the unified log on macOS 26,
/// so debug breadcrumbs go to a flat file instead: `~/Library/Logs/Notch/notch.log`
/// (`./build.sh logs` to follow).
private let notchLogURL: URL = {
    let fm = FileManager.default
    let dir = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Notch", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("notch.log")
    // Unlike /tmp, ~/Library/Logs survives reboots — rotate once per launch
    // so the file can't grow without bound.
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5_000_000 {
        let old = dir.appendingPathComponent("notch.log.old")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
    }
    return url
}()

func notchLog(_ msg: String) {
    let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    let fm = FileManager.default
    if !fm.fileExists(atPath: notchLogURL.path) {
        fm.createFile(atPath: notchLogURL.path, contents: nil)
    }
    if let fh = try? FileHandle(forWritingTo: notchLogURL) {
        defer { _ = try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
    }
}
