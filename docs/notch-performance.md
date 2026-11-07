# Whole-app benchmark plan and runner

This suite covers Notch's feature areas and representative interactions, including
combined load. **Claude is excluded.** A coverage matrix distinguishes automated
fixture measurements from real-app, account, permission and hardware checks. It does
not claim exhaustive coverage of every combination of macOS, device and external app.

## Run the automated suite

```sh
./scripts/benchmark-notch.sh
./scripts/benchmark-notch.sh --samples 30 --soak-seconds 60
# Extended allocation/resource trend run (up to one hour):
./scripts/benchmark-notch.sh --samples 30 --soak-seconds 1800
```

Requires macOS, Swift and Python 3. A graphical session is needed for hosted views;
without one those checks are marked incomplete, not passed. Use a quiet Mac, fixed
display scaling/refresh rate, the same power mode, and three runs for comparisons.
Each run gets a new directory under `.build/benchmarks/notch-TIMESTAMP/`. `--output`
may name another **new** directory. Compilation time is excluded from measurements.

The runner freezes Sources/Tests/Package.swift, checks hashes before and after the
copy, and builds in that copy. This avoids other development work changing code
during a benchmark. Reports retain source hashes, OS/Swift/hardware metadata,
individual measurements, XCTest results, synthetic logs, renders and coverage status.
The copies include build products and can be deleted when no longer needed.

Some SwiftPM toolchains do not emit the requested `tests.xml`. In that case the
runner retains `tests.log` as the correctness evidence and notes the missing XML.

The release build adds `NOTCH_BENCHMARK`. That flag exposes narrow fixture entry
points into the real music-display update, audio processing, Spotify cache decoding
and screenshot scanner, and redirects logs into the report folder. Shipping builds
do not include these accessors. Settings and docking use an isolated defaults suite;
screenshots use temporary folders and a private pasteboard. The suite never calls
AppEnvironment.start, creates audio taps, requests permissions, sends media commands,
reads personal rollouts, writes Spotify accounts, or installs agent hooks.

## What is measured

| Area | Automated workload | Correctness checked |
| --- | --- | --- |
| State and docking | Open/close, hover, music/screenshots tabs, mutually exclusive foldouts, all three docks, 0/1/5/20 session row sizes, delayed close | Panel bounds, cleared preview/foldouts, persisted dock, timer delivery |
| Settings | Local clipboard/Codex/podcast toggles; reconstructed SettingsStore; simulated screenshot-routing enable/disable | Saved values and restoration of prior screenshot location |
| Music | 100 metadata changes with long/unicode titles and podcast states | Display state changes, elapsed playback, clearing stopped content |
| Audio meter | Actual six-filter DSP and publication for silence/tone; 44.1/48/96 kHz, 512/2048 stereo frames | Finite, bounded bar values; no system capture permission required |
| Spotify | Decode/rebuild 1,000 and 100,000 playlist memberships; 1,000 current-track lookups per operation | Playlist counts, liked and playlist membership, clearing current track |
| Screenshots | Cold start and cached scan at 0/100/1,000/10,000 files; real filesystem watcher; 4K thumbnail/clipboard; main-actor heartbeat and Codex delivery during a cold 10K-file scan | Seven-item strip; event delivery; bounded thumbnails; private clipboard; pipeline regression suite for races, recovery, corruption and cleanup |
| Codex | Existing discovery/log benchmark, plus worker → main-thread state → toast | Expected completion and visible-state transition; original replay/backlog checks |
| Views | 11 states at each dock plus Settings: empty, playing collapsed, hover, music, podcast, playlists, screenshots, 20 sessions, completion and screenshot banners, overlay-hidden | Hosted bitmap successfully generated; PNGs saved for separate visual review |
| Logging | 100 records per operation with an 8 KiB rotation limit | Bounded current log; existing privacy/rotation/concurrency tests also run |
| Combined soak | A sustained 30 Hz fixture loop with DSP, cursor updates, hosted draws, Codex events, filesystem events, library lookups and tab changes | Main-thread scheduling lateness, completion delivery, process CPU/RSS/threads/descriptors over time |

The machine-readable source of coverage is
[notch-benchmark-scenarios.json](notch-benchmark-scenarios.json). `coverage.json` and
`REPORT.md` show what actually ran. Existing release-safety tests supply additional
routing-failure, launch-guard, log-permissions and concurrency assertions.

## Reading the measurements

Each whole-app component has two warmups and the requested samples; expensive folder
scans, hosted renders and clipboard operations cap measured samples at five. Event
delivery and delayed close use three measured samples. The original Codex suite
keeps its own three warmups and ten-sample startup cap.

- **Wall p50/p95/max:** elapsed operation time, including any explicit waits inside
  that operation. Screenshot delivery includes file writing, the 300 ms debounce and
  main-thread delivery. Codex worker-to-toast includes queue delivery but starts a
  poll immediately, so it excludes the app's one-second scheduling delay. Timings
  include small correctness predicates; fixture generation is otherwise outside.
- **CPU milliseconds:** process user + system time over the operation. Async tests
  include any concurrent work in the test runner. Short DSP samples are near timer
  resolution; compare distributions and increase samples before drawing conclusions.
- **RSS, threads, descriptor estimate:** the entire test process, including AppKit,
  XCTest, fixtures, caches and renderer. Sampled between operations; not an allocation
  profile or the peak within an operation. `fdCapacityEstimate` is the kernel's size
  query, not an exact descriptor count. The live sampler enumerates actual descriptors.
- **Hosted rendering:** synchronous AppKit/SwiftUI bitmap draws after view setup.
  Warm draws can benefit from caches. They are not cold launch, compositor frames,
  GPU utilization or measured animation FPS. PNG generation succeeding does not
  establish visual correctness. Inspect representative renders. Screenshot root
  renders can retain placeholders in this offscreen/cropped host; a separate hosted
  screenshot-strip regression checks decoded pixels. Root render timings are not
  measurements of image-loading cost.
- **Combined soak:** actual CPU divided by elapsed time, with one core = 100%.
  Main-actor wake lateness is measured against a 30 Hz schedule, with missed ticks
  dropped. Forced bitmap capture is additional harness work. Synthetic audio runs
  once per tick, not at a real audio device's callback cadence. Treat these numbers
  as a repeatable stress baseline, never as the shipping app's battery consumption.

A ten-second soak is a smoke test, not evidence of stability or leak freedom.
Use at least 30 minutes and compare post-warmup/post-cooldown resource trends for
retention investigations. Allocator high-water marks and image caches can retain RSS
without leaking. Instruments Allocations/Leaks is needed for attribution.

## Live-app benchmark protocol

Use the installed optimized app in a test account. Disable Claude monitoring before
collecting this suite. The sampler doesn't toggle it, inspect its settings, grant
permissions or drive your apps. Arrange each scenario below, warm up for 30 seconds,
then capture five minutes with a meaningful label:

```sh
./scripts/sample-notch.sh --pid YOUR_NOTCH_PID \
  --scenario idle-collapsed-codex-off --seconds 300 \
  --output .build/benchmarks/live/idle-off.json --claude-disabled
```

`--claude-disabled` records the operator's confirmation; it is not an automatic
check. PID identity is checked throughout so exit/reuse doesn't become a misleading
pass. The sampler only reads counters: per-interval and mean CPU, RSS, virtual memory,
thread/descriptor counts, page-ins, faults and context switches. It does not aggregate
child processes or measure disk/network traffic, wakeups, GPU work or energy.

| Live scenario | Steps and variants | Evidence / acceptance |
| --- | --- | --- |
| Launch and onboarding | Fresh account/install; launch three times; deny then grant required permissions; reopen Settings; quit/relaunch; upgrade | Process launch → first visible notch and usable control timestamps; no stuck prompt/crash; correct restored settings |
| Idle | No music, no sessions; collapsed then open; Codex off then on | Paired five-minute process samples; explain any continuous work; repeat after 30 s cooldown |
| Music | Play/pause, previous/next, rapid skip, seek, long track/artist, missing/changing artwork, stop player | Correct labels/progress/art/control action; response latency and frame trace at top/left/right |
| Podcast | 15/30 s skip, 1×/1.5×/2×, seek near start/end, hour-long episode | Correct elapsed time and command destination; no label clipping or growing CPU |
| Audio capture | Grant/deny, silence/speech/music, pause for >2 s, change output/Bluetooth device, resume | Tap stops after pause debounce, no duplicate aggregate devices; record CPU before/after |
| Spotify auth/sync | Test account login, cancel/retry, occupied callback port, token expiry, offline, denied/rate-limited API, small/large library, unchanged/changed playlists | Correct error/recovery and bounded request work; use Network Instruments or stub-server tests before claiming API coverage |
| Spotify writes | Like/unlike and add/remove on disposable test items; change track during request; fail network | Exactly intended item changes; correct optimistic state/rollback; restore test account afterward |
| Screenshots | Region/window/full-screen captures; supported formats; burst; non-images; folder at 0/100/1K/10K; custom route change; clipboard on/off; drag/open/scroll | Actual OS capture → displayed thumbnail/toast latency; clipboard contents and strip order; no unexpected non-screenshot items |
| Cleanup | Populate a disposable screenshot folder plus unrelated files; trigger cleanup; restore captures from Trash | Only intended captures moved; directory routing preserved; never use personal screenshots as destructive fixtures |
| Input and docking | Hover/leave/click, scrubber/control clicks, horizontal tab swipes, thumbnail scroll; all six directed edge drags; release outside window; repeat rapidly | Correct hit targets, no accidental drag, no stranded landing, correct dock after relaunch; frame trace |
| Codex | Existing and newly started CLI/app-server sessions; 1/5/20; same folder; tool burst; complete/interrupt/resume/exit; Terminal and VS Code focus | Record a real action timestamp and first visible corresponding state; correct session identity/focus; no false toast from history |
| Overlap | Music playing while screenshot arrives and several Codex sessions complete; interact while a banner auto-closes | Deliberate banner replacement behavior, responsive controls, no stuck-open state |
| macOS windows | Space swipe, full-screen apps, Mission Control, Exposé, Launchpad, Show Desktop, hot corners | Retracts/returns correctly and doesn't steal input; inspect with actual system overlays |
| Displays | Notched/non-notched; 60/120 Hz; Retina scaling; two displays, menu-bar relocation, disconnect, clamshell | Position/size and hit-testing stay aligned; trace actual frame presentation on each refresh rate |
| Sleep and power | Lock/unlock, sleep/wake, output-device changes, AC/battery/low-power modes | Services recover, timers don't multiply, state reflects current media/sessions |
| Accessibility | Keyboard/VoiceOver, reduced motion, high contrast, light/dark, long/unicode content; revoke permissions mid-use | Controls remain understandable/reachable; graceful failure and recovery |
| Login/install | Register/unregister login item and approval states; DMG launch guard; restart login; uninstall in disposable account | Correct system registration and no unexpected data/settings changes |
| Soak/recovery | 30–60 minutes of mixed activity, session/folder churn, malformed/truncated/replaced rollouts and offline recovery | No crash/stuck state; plot CPU/RSS/FD/thread trends and compare after 30 s cooldown |

Measure user input → visible response and animation smoothness with Instruments
Animation Hitches/Core Animation or a timestamped screen recording. Use Time Profiler
for CPU attribution, Allocations for memory, and Energy Log/Power Profiler where
available for energy. The process sampler alone cannot supply these metrics.

## Initial investigation budgets

These are proposed engineering targets, not hardware-independent pass/fail assertions:

- Idle app: mean below 1% of one core over five minutes after warmup, no growing
  threads/descriptors after repeated cycles. Compare Codex off/on separately.
- Local input → visible response: p95 below 100 ms. Animation frame budget follows
  the display: 16.7 ms at 60 Hz, 8.3 ms at 120 Hz. Hosted bitmap timings cannot pass
  this criterion.
- Main-thread operations: investigate operations over 50 ms, especially folder
  scans and large library rebuilds. These can block every other feature at once.
- Screenshot delivery: p95 below 750 ms after the file is readable, allowing the
  intended 300 ms debounce. Codex: below 1.5 s after a lifecycle record is written,
  allowing its 1 Hz poll. These are live expectations, not immediate-poll test claims.
- Resource retention: after repeated cycles and cooldown, investigate sustained
  growth; don't set a universal RSS ceiling from one test machine.

Correctness failures make the automated command fail. Timing budgets prompt
investigation and are not enforced as flaky wall-clock assertions. Keep unsuccessful
reports as evidence; do not merge their partial data into a passing baseline.

## Existing Codex baseline

The original narrow benchmark and its recorded results remain in
[codex-performance.md](codex-performance.md). Whole-app results must be collected
with this expanded suite; those earlier figures do not describe the whole app.

## First expanded-suite validation — 2026-09-27

Historical harness note: these initial runs allowed synthetic Spotify track changes
to schedule background sync attempts, which failed without a connected account.
That contaminated mixed-workload/Spotify measurements. Fixture libraries now block
external sync before any keychain access; use reports produced after that correction
for those measurements. Shipping builds are unaffected by this benchmark-only guard.

Validated with `--samples 10 --soak-seconds 10` on Mac14,7, 8 GiB RAM, macOS 26.3,
Swift 6.3.3. This is a smoke baseline, not a three-run statistical comparison.
The optimized command passed 24 XCTest cases, including both benchmark cases.
There are 65 whole-app measurement rows plus the original Codex component report.
Coverage: 11 automated areas passed, 17 live areas not run, Claude excluded.

Selected p95 observations:

| Operation | Time |
| --- | ---: |
| Screenshot folder scan, 100 mixed files | 13.5 ms |
| Screenshot folder scan, 1,000 mixed files | 133.5 ms |
| Screenshot folder scan, 10,000 mixed files | 1,251.2 ms |
| Real filesystem event → screenshot callback (includes write/debounce) | 307.2 ms |
| 4K image → 400 px thumbnail | 26.8 ms |
| 4K private-pasteboard conversion | 34.6 ms |
| Spotify decode/index, 100,000 memberships | 33.4 ms |
| Audio DSP plus publication, 2,048 stereo frames | About 0.022 ms |
| Immediate Codex poll → state/toast | 2.1 ms |

At this historical baseline, screenshot scans ran on the main thread. The 1K/10K
cases exceeded the 50 ms investigation budget. That finding led to the background
pipeline described in [screenshot-pipeline.md](screenshot-pipeline.md); see the later
validation below for the implemented fix.

The 10-second combined harness used about 111% of one core, including forced
30 Hz bitmap drawing. Its main-actor wake lateness p95 was 5.2 ms, with 271 ticks
and nine injected turns. RSS went from approximately 135 to 149 MiB during that
phase; the descriptor capacity estimate stayed at 45. This is an intentionally busy
test harness, not a live-app CPU, battery or leak measurement.

The initial run also exposed a correctness bug in log rotation: cached URL file-size
metadata could let many small appends exceed the limit. The logger now reads fresh
file attributes, and a new 1,000-append regression test verifies both rotated files
stay bounded. A separate harness path-comparison issue was corrected by resolving
temporary-directory symlinks before checking screenshot delivery.

Representative music, playlist, session-list and banner PNGs were inspected. The
live sampler was smoke-tested against a disposable process, including early process
exit; that is validation of the sampler, not a live Notch measurement.

Local evidence: `.build/benchmarks/notch-20260927T205912Z/REPORT.md`, `notch.json`,
`codex.json`, `coverage.json`, `tests.xml`, `tests.log` and `renders/`. Generated files
are ignored by Git; the summary above preserves the results.

## Corrected 60-second run — 2026-09-27

Run: `.build/benchmarks/notch-20260927T210942Z/`, with 30 requested samples
(the documented per-scenario caps still apply) and a 60-second mixed workload.
All 24 XCTest cases passed, with 65 whole-app measurements plus Codex components.
Eleven automated coverage areas passed; 17 live areas remain unrun and Claude is
excluded. No Spotify sync/API entries appeared after the fixture-isolation fix.
The prior `notch-20260927T210638Z` run is superseded for performance interpretation.

| Selected operation | p95 |
| --- | ---: |
| Screenshot scan, 100 / 1,000 / 10,000 mixed files | 13.2 / 127.7 / 1,280.2 ms |
| Screenshot event delivery, including write and debounce | 307.6 ms |
| 4K thumbnail / private clipboard conversion | 23.9 / 34.4 ms |
| Spotify index rebuild, 100,000 memberships | 34.5 ms |
| Audio DSP and publication, 2,048 stereo frames | About 0.019 ms |
| Immediate Codex worker → state/toast | 2.1 ms |
| Five active Codex sessions, scan only | 1.15 ms |

The mixed phase completed in 60.02 seconds with 54 injected turns and 1,623
scheduled work ticks. Actual test-process CPU averaged 106.3% of one core,
including forced bitmap drawing; this is not ordinary Notch CPU usage.
Main-actor wake lateness p95 was 10.1 ms, maximum 27.7 ms. Phase-start/end RSS
was 203.6/59.9 MiB as earlier fixture/render allocations were released. Descriptor
capacity estimates stayed at 45; thread counts ended at 10. This short run showed
no net memory growth in that phase, but does not establish leak freedom.

Screenshot scanning remains the main performance concern because the large-folder
work runs on the main thread. Hosted draws for 20-session panels also reached
49.1 ms p95 in one dock configuration; these are bitmap costs, not measured screen
frame times. Raw samples and all other timings are retained in the run report.

## Screenshot pipeline implementation — 2026-09-27 (final run 2026-09-28 UTC)

Implementation details and limits are in [screenshot-pipeline.md](screenshot-pipeline.md).
The optimized app bundle was rebuilt and its local code signature verified. The
normal release configuration passed **42 tests**, including 20 screenshot pipeline
regressions. The final whole-app command (`--samples 30 --soak-seconds 60`) passed
**44 tests**, with 71 whole-app measurement rows plus the Codex component report.
Claude remained excluded; the 17 live/account/hardware scenarios remain not-run.

Authoritative final artifacts:
`.build/benchmarks/notch-20260928T010305Z/` (`REPORT.md`, `tests.log`, `notch.json`,
`codex.json`, `renders/`, source hashes and environment metadata). Source/Tests/Package
hashes matched the working tree after the run. Screenshot folder-error layouts were
visually checked at all three docks. A separate hosted-view pixel assertion verifies
that an actual decoded screenshot replaces its placeholder.

| Measurement (p95 unless stated) | Prior baseline | Final implementation |
| --- | ---: | ---: |
| Repeated scan, 100 mixed files | 13.158 ms, main thread | 2.153 ms, background |
| Repeated scan, 1,000 mixed files | 127.654 ms, main thread | 8.317 ms, background |
| Repeated scan, 10,000 mixed files | 1,280.162 ms, main thread | 87.247 ms, background |
| Cold 10K discovery + watch setup + reconciliation | Not separately measured | 1,491.865 ms, background |
| Main-actor scheduling lateness during cold 10K scan | Not separately measured | 1.060 ms p95; 1.071 ms max |
| Immediate Codex poll → toast during cold 10K scan | Not separately measured | 2.085 ms |
| Filesystem write → capture callback, including debounce/readiness | 307.558 ms | 346.791 ms |
| 4K thumbnail | 23.937 ms | 23.166 ms |
| 4K private-pasteboard conversion/commit | 34.378 ms | 31.177 ms |

The repeated 10K scan is about **14.7× faster** in these samples. Cold folder
classification remains substantial work; the primary usability improvement is that
it no longer monopolizes the main thread. The new callback includes a real readiness
check, and its measured delay remains below the proposed 750 ms investigation target.
Five measured scan/clipboard samples and three delivery samples are small samples;
these figures are observations on this Mac, not universal guarantees.

### Mixed-workload finding and harness correction

Do **not** treat the combined-render result as a clean bill of UI performance. The
final 60.057-second workload passed its functional checks, but main-actor scheduling
lateness was **63.023 ms p95 / 75.938 ms max**, above an animation frame budget. It
executed 942 ticks and 31 synthetic turns. Process CPU was 24.73% of one core; RSS
went from 347.27 to 85.69 MiB; descriptor capacity stayed 45; thread count went from
41 to 45. These are whole test-process observations, not shipping idle CPU, energy,
frame presentation or proof of leak freedom.

Before explicit fixture teardown, the same shipping code produced 82.63 ms p95 and
406.41 ms max; a repeat produced 85.67 ms p95 and 322.82 ms max. Both runs passed
correctness. At that time the machine reported elevated memory pressure and roughly
6 GiB of swap use. A one-second process sample showed substantial main-thread
SwiftUI/AppKit layout/transaction work, with thumbnail decoding on the dedicated
background queue. This is a limited sample, not proof that all delay has one cause.

The harness now replaces closed hosting views with EmptyView and detaches window
content, preventing prior view fixtures from continuing their original work during
later measurements. That reduced mixed-workload CPU and extreme delays, but did not
eliminate scheduling lateness. The reported application window inventory still
included 38 windows (including closed harness windows). Further clean-machine/live
Instruments work is needed before attributing the remaining delay or claiming smooth
production frame delivery. Older mixed-workload CPU figures are not directly
comparable across this harness teardown change.

Retained investigation evidence:
`.build/benchmarks/notch-20260928T005601Z/` and its `repeat-whole-app/` subdirectory
(including `system-before.txt`, `system-after.txt`, `process-sample.txt`). The repeat
was sampled briefly and is diagnostic evidence, not an uninstrumented reference run.
Earlier failed symlink test reports were retained; the final suite verifies the fix.
