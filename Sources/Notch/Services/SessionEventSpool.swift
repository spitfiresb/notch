import Foundation
import Darwin

/// Independent buffers and offsets prevent interleaving Claude and Codex events.
@MainActor
final class SessionEventSpool {
    let url: URL
    var onEvent: (([String: Any], Date, pid_t?, Bool) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var pending = Data()

    init(url: URL) { self.url = url }

    func start() {
        stop()
        offset = 0
        pending.removeAll()
        readNew(replaying: true)
        truncateConsumed()
        watch()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func watch() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self.stop()
                self.offset = 0
                self.pending.removeAll()
            }
            self.readNew()
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    func readNew(replaying: Bool = false) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        if source == nil && !replaying { watch() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; pending.removeAll() }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        // Advance by the bytes actually read: a writer can append after seekToEnd.
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            ingest(chunk, replaying: replaying)
        }
        if !replaying && offset > 4_000_000 { truncateConsumed() }
    }

    /// Preserve the existing spool retention policy. Never discard a partial line.
    private func truncateConsumed() {
        guard pending.isEmpty, offset > 0,
              let writer = try? FileHandle(forWritingTo: url) else { return }
        defer { try? writer.close() }
        guard (try? writer.seekToEnd()) == offset else { return }
        do {
            try writer.truncate(atOffset: 0)
            offset = 0
        } catch { notchLog("sessions: spool truncate failed: \(error)") }
    }

    func ingest(_ data: Data, replaying: Bool = false) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let event = object["event"] as? [String: Any] else { continue }
            let date = (object["ts"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
            let pid = (object["pid"] as? Int).flatMap { $0 > 1 ? pid_t(exactly: $0) : nil }
            onEvent?(event, date, pid, replaying)
        }
    }
}
