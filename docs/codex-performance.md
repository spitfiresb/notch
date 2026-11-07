# Codex monitoring performance benchmark

Run from the repository root:

```sh
./scripts/benchmark-codex.sh
# More samples, with a stable report location:
NOTCH_BENCHMARK_SAMPLES=100 ./scripts/benchmark-codex.sh .build/benchmarks/codex.json
```

The benchmark uses the production `CodexSessionMonitor.scan()`, reader and parser in
an optimized release XCTest process. It is opt-in and skipped by ordinary test runs.
It creates and removes synthetic rollout files in the temporary directory. It does
not start the app, change agent settings, invoke a model, or read personal chats.
Native discovery enumerates process identities only; descriptor discovery inspects
the test process's own synthetic open files.

## Workloads

| Scenario | Operation measured |
| --- | --- |
| Native process discovery | Enumerate real machine processes and identify Codex binaries; no rollout reads |
| Native descriptor discovery | Inspect the test process with 20 synthetic rollout files held open |
| Idle: 0, 1, 5, 20 sessions | Scan already discovered files with no appended data |
| Active: 1, 5, 20 sessions | Append one complete turn per session per scan, including a 4 KiB tool result |
| Heavy: 5 sessions | Same turn sequence, with a 256 KiB tool result per session per scan |
| Initial replay | Discover one 16 MiB history and replay the reader's bounded tail |
| Backlog correctness | Append just over 8 MiB; check the number of bounded scans needed and that every lifecycle event arrives exactly once |

Synthetic scans inject exact process/file mappings, so they isolate file opening,
metadata checks, incremental reads, JSON parsing, and event construction. Native
discovery costs are reported separately, not silently included or added together.
Active workloads are synthetic load levels, not a claim about typical user traffic.
Writes happen before each measurement and use the filesystem cache, as newly written
live rollouts usually would. Initial replay is warm-cache replay, not cold-disk I/O.

## Metrics and interpretation

Each timing scenario has three warmups followed by 30 samples by default (5–1000
configurable). Initial replay is capped at ten measured samples. JSON retains every
sample, with wall-time p50/p95/max, mean process CPU time, sampled resident memory,
bytes appended, event counts and machine metadata. A companion environment file
records Swift/OS versions, hardware model, Git revision, dirty file names and hashes
of the monitor, session store and benchmark sources.

- **Wall time:** time spent executing one synchronous scan/component operation.
  It excludes the one-second timer wait, queue dispatch, main-thread state updates,
  SwiftUI rendering and animations. This is not end-to-end notification latency.
- **CPU time:** process user + system CPU elapsed across the operation (`getrusage`).
  The test runner's other threads can contribute noise. Sub-millisecond values are
  especially sensitive to timer resolution and scheduling.
- **Projected CPU at 1 Hz:** mean CPU milliseconds divided by ten. For example,
  2 ms per scan projects to 0.2% of one core at one scan per second. Samples run
  back-to-back; this is a projection, not measured idle CPU, energy or battery drain.
  The initial-replay row is a one-time startup cost; its hypothetical 1 Hz projection
  does not describe steady-state monitoring.
- **Resident memory:** whole test-process RSS before/after a scenario and after each
  measured operation. It includes XCTest, loaded app code, fixtures and allocator
  caches. It is neither isolated monitor memory nor the peak inside a scan; scenario
  order can affect it. The 2 MiB reader budget is not a total memory limit.
- **Backlog:** scans needed to catch up. At the app's one-second cadence, several
  scans mean several seconds of catch-up even if each scan executes quickly.

Fixture generation, append writes, ordinary event-count assertions, memory sampling,
autorelease-pool draining and report serialization are outside timed operations.
Replay includes its two small correctness checks; native descriptor discovery also
includes canonicalizing/filtering the discovered paths to verify the fixture.

## Evaluating a baseline

Run three times on the same machine with the same power mode and similar background
load. Compare the same scenario and sample count. Treat these as initial engineering
budgets to investigate, not portable test assertions:

- Idle five-session scan plus native discovery: comfortably below 10 ms mean CPU
  per second (1% of one core), accounting for descriptor inspection per process.
- Active five-session scan: p95 below 50 ms; heavy five-session scan: p95 below 100 ms.
- Correctness: no missing/duplicate lifecycle events, no repeated events after EOF,
  and an 8 MiB backlog drains in the expected number of 2 MiB reads.
- Memory: investigate sustained growth with increased sample counts; do not call a
  single RSS delta a leak. Use Allocations/Instruments for attribution if needed.

Correctness assertions fail the run. Timing budgets are advisory because hardware
and background activity vary. JSON written by a failing test is not a passing baseline;
the runner exit status is authoritative.

To measure the full app later, compare monitoring off/on with identical sessions,
music state and notch visibility over several minutes using Instruments Time Profiler
and Energy Log. Capture timer wakeups, process CPU, allocations and visible-event
latency. These component numbers alone cannot establish battery impact or UI smoothness.

## Local baseline — 2026-09-27

Three successful release runs on Mac14,7, 8 logical CPUs, 8 GiB RAM, macOS 26.3,
Swift 6.3.3. Each used 30 samples per scenario (ten for startup) after three warmups.
The ranges below span the three runs, not confidence intervals. Background developer
activity was not controlled. Concurrent source edits interrupted an additional build;
the final two successful runs used a frozen temporary source copy. Source hashes for
that copy are saved locally in `.build/benchmarks/snapshot.json`.

| Component/workload | Wall p95 per operation | Mean CPU per operation | Projected one-core CPU at 1 Hz |
| --- | ---: | ---: | ---: |
| Native process discovery | 1.22–1.49 ms | 1.08–1.17 ms | 0.108–0.117% |
| Native descriptor discovery, 20 open fixtures in one process | 0.61–0.69 ms | 0.55–0.56 ms | 0.055–0.056% |
| 5 idle sessions, scan only | 0.10–0.11 ms | 0.09–0.10 ms | 0.009–0.010% |
| 5 active sessions, scan only | 1.22–1.36 ms | 1.05–1.09 ms | 0.105–0.109% |
| 20 active sessions, scan only | 4.86–6.95 ms | 4.22–4.43 ms | 0.422–0.443% |
| 5 heavy-output sessions, scan only | 21.72–43.43 ms | 19.85–21.34 ms | 1.985–2.134% |
| Initial replay of a 16 MiB history | 93.38–110.97 ms | 86.40–91.05 ms | One-time cost |

Normal five-session scans were inexpensive in this workload. Heavy output cost much
more, and its wall-time tail varied with scheduling/load. Both scan workloads remained
within the initial advisory timing budgets. Native discovery remains a separate cost;
the descriptor row is one process holding 20 files, not 20 real Codex processes.

The test process started near 21.5 MiB RSS and reached sampled maxima of 32.2–35.1 MiB
across the entire suite. This includes fixture and test-runner memory, and cannot be
reported as the app's monitoring overhead or used to rule out a long-running leak.

All three benchmark runs passed their correctness checks. The 8,405,984-byte backlog
drained in five scans each time without missing or duplicate lifecycle events. The
related release tests passed: nine rollout tests and seven session tests. An ordinary
test invocation also confirmed that the performance benchmark skips without opt-in.

Raw local reports: `.build/benchmarks/codex-baseline-1.json`,
`codex-baseline-2.json`, and `codex-baseline-3.json` in the same directory. These generated
files are ignored by Git; this section preserves the baseline summary.
