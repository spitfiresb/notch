import Foundation

/// Per-process inbound byte counters, sampled once a second by a long-lived
/// `nettop` for exactly the processes we're asked to watch.
///
/// Why: Ctrl-C while Claude is still thinking (no output yet) leaves no trace
/// anywhere — no hook, nothing in the transcript. What *does* change is the
/// wire: a turn in flight is an open SSE stream from the API that delivers a
/// few hundred bytes every second (tokens or pings), and aborting it closes
/// the stream. A `claude` process sitting at the prompt receives nothing for
/// tens of seconds at a time, bar the odd 40–700 byte keepalive. So "no
/// inbound bytes for a few seconds while the session claims to be thinking"
/// means the turn is gone.
///
/// `nettop` is the only public way to read another process's byte counters
/// (the counters behind it are a private framework). One process, spawned only
/// while there's something to watch, restarted when the pid set changes.
@MainActor
final class NetworkActivityMonitor {
    private struct Sample { let at: Date; let bytesIn: UInt64 }

    private var process: Process?
    private var watched: Set<pid_t> = []
    private var samples: [pid_t: [Sample]] = [:]
    private var pending = Data()

    /// Keep this many seconds of samples per process.
    private static let horizon: TimeInterval = 12

    /// Watch exactly `pids` — start, stop, or restart `nettop` as needed.
    func watch(_ pids: Set<pid_t>) {
        guard pids != watched else { return }
        stop()
        watched = pids
        samples = samples.filter { pids.contains($0.key) }
        guard !pids.isEmpty else { return }
        start(pids)
    }

    /// Bytes received over (at least) the last `window` seconds, or nil when
    /// there isn't a sample old enough to say yet.
    func bytesIn(_ pid: pid_t, over window: TimeInterval, now: Date = Date()) -> UInt64? {
        guard let s = samples[pid], let last = s.last,
              let base = s.last(where: { now.timeIntervalSince($0.at) >= window }),
              last.bytesIn >= base.bytesIn else { return nil }
        return last.bytesIn - base.bytesIn
    }

    // MARK: nettop

    private func start(_ pids: Set<pid_t>) {
        let p = Process()
        // Under a pseudo-terminal (`script`): writing to a pipe, nettop
        // block-buffers and its samples arrive in kilobyte lumps minutes
        // late; on a tty they come out line by line, every second.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // -P per-process, -L 0 forever, -s 1 every second, -x raw numbers,
        // -c collapsed (no per-connection rows), CSV with just bytes_in.
        var args = ["-q", "/dev/null", "/usr/bin/nettop",
                    "-P", "-L", "0", "-s", "1", "-x", "-c", "-J", "bytes_in"]
        for pid in pids { args += ["-p", String(pid)] }
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data) }
        }
        do {
            try p.run()
            process = p
            notchLog("net-activity: watching \(pids.sorted())")
        } catch {
            notchLog("net-activity: nettop failed to start: \(error)")
        }
    }

    private func stop() {
        guard let p = process else { return }
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        p.terminate()
        process = nil
        pending.removeAll()
    }

    /// Lines look like `2.1.248.49848,680804,` (process name, then pid, then
    /// the cumulative counter); a header row `,bytes_in,` precedes each sample.
    private func ingest(_ data: Data) {
        pending.append(data)
        let now = Date()
        while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                .trimmingCharacters(in: .init(charactersIn: "\r"))   // tty line endings
            pending.removeSubrange(pending.startIndex...nl)
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2, !fields[0].isEmpty,
                  let pidText = fields[0].split(separator: ".").last, let pid = pid_t(pidText),
                  let bytes = UInt64(fields[1]) else { continue }
            var list = samples[pid] ?? []
            list.append(Sample(at: now, bytesIn: bytes))
            list.removeAll { now.timeIntervalSince($0.at) > Self.horizon }
            samples[pid] = list
        }
    }
}
