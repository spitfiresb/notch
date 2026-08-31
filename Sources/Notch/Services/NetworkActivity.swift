import Foundation

/// Per-process inbound byte counters, sampled once a second by a short-lived
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
/// (the counters behind it are a private framework), but its continuous
/// logging mode (`-L 0`) busy-spins at well over a full core no matter the
/// `-s` interval — so we take one `-L 1` sample per second instead, which
/// costs ~6 ms of CPU a piece. The counters are cumulative per process, not
/// per `nettop` run, so readings compose across invocations exactly as they
/// did from one long-lived child.
@MainActor
final class NetworkActivityMonitor {
    private struct Sample { let at: Date; let bytesIn: UInt64 }

    private var timer: Timer?
    /// A sample still in flight — never let spawns pile up behind a slow one.
    private var sampling = false
    private var watched: Set<pid_t> = []
    private var samples: [pid_t: [Sample]] = [:]

    /// Keep this many seconds of samples per process.
    private static let horizon: TimeInterval = 12
    private static let interval: TimeInterval = 1
    private static let queue = DispatchQueue(label: "notch.net-activity", qos: .utility)

    /// Watch exactly `pids`. Unlike the long-lived child this replaced, a
    /// changed pid set needs no restart — the next tick simply asks for the
    /// new set.
    func watch(_ pids: Set<pid_t>) {
        guard pids != watched else { return }
        watched = pids
        samples = samples.filter { pids.contains($0.key) }
        if pids.isEmpty { stop() } else if timer == nil { start() }
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

    private func start() {
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        notchLog("net-activity: watching \(watched.sorted())")
        sample()   // seed the window rather than waiting out the first tick
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard !sampling, !watched.isEmpty else { return }
        sampling = true
        let pids = watched
        Self.queue.async { [weak self] in
            let out = Self.runNettop(pids)
            Task { @MainActor in
                guard let self else { return }
                self.sampling = false
                if let out { self.ingest(out) }
            }
        }
    }

    /// One `-P` per-process, `-L 1` single CSV sample, `-x` raw numbers,
    /// `-c` collapsed (no per-connection rows), just the `bytes_in` column.
    private nonisolated static func runNettop(_ pids: Set<pid_t>) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        var args = ["-P", "-L", "1", "-x", "-c", "-J", "bytes_in"]
        for pid in pids.sorted() { args += ["-p", String(pid)] }
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            notchLog("net-activity: nettop failed to start: \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    /// Lines look like `2.1.248.49848,680804,` (process name, then pid, then
    /// the cumulative counter); a header row `,bytes_in,` precedes the sample.
    private func ingest(_ data: Data) {
        let now = Date()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.trimmingCharacters(in: .init(charactersIn: "\r"))
                .split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2, !fields[0].isEmpty,
                  let pidText = fields[0].split(separator: ".").last, let pid = pid_t(pidText),
                  let bytes = UInt64(fields[1]),
                  // A sample can land after `watch` dropped the pid — don't
                  // resurrect counters for something we no longer track.
                  watched.contains(pid) else { continue }
            var list = samples[pid] ?? []
            list.append(Sample(at: now, bytesIn: bytes))
            list.removeAll { now.timeIntervalSince($0.at) > Self.horizon }
            samples[pid] = list
        }
    }
}
