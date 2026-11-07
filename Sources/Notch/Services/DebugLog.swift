import Foundation

/// A bounded, private log. Rotation happens during use, not only on relaunch.
final class BoundedLog: @unchecked Sendable {
    let url: URL
    let limit: Int
    private let lock = NSLock()

    init(url: URL, limit: Int = 5_000_000) {
        self.url = url
        self.limit = limit
    }

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // Limit individual records and remove the home path from incidental errors.
            let cleaned = message.replacingOccurrences(of: fm.homeDirectoryForCurrentUser.path, with: "~")
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(cleaned.prefix(4096))\n"
            let data = Data(line.utf8.prefix(limit))
            // URL.resourceValues may reuse a cached size after repeated appends.
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > limit {
                let old = url.appendingPathExtension("old")
                if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
                if fm.fileExists(atPath: url.path) { try fm.moveItem(at: url, to: old) }
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: old.path)
            }
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { /* Diagnostics must never interrupt the app. */ }
    }
}

private let log = BoundedLog(url: FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Notch/notch.log"))

func notchLog(_ message: String) { log.append(message) }
