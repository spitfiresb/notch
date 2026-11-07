# Screenshot pipeline

Screenshot discovery and image preparation run on serial background queues. The
main actor schedules work, publishes at most seven file records, displays feedback,
and commits prepared clipboard data. Large folders no longer require a synchronous
main-thread enumeration/Spotlight scan.

## Work and resource limits

- One scan in flight per watcher, with one coalesced follow-up. A generation and
  cancellation token prevent a stopped or rebound watcher from publishing stale data.
- Folder events trigger a bounded 300 ms debounce. Continuous writes cannot keep
  postponing the scan. Watch installation is followed by a reconciliation scan to
  cover captures arriving between enumeration and installing the watch.
- Unchanged file identities/signatures reuse screenshot classification. Negative
  Spotlight classifications expire after 60 seconds for delayed indexing/localized
  names. The cache is pruned to files still present in the current directory.
- A 30-second recovery check replaces the old unconditional 3-second scan. It checks
  the directory signature and can skip enumeration; at least every 60 seconds it
  reconciles file metadata to recover missed events and in-place changes.
- Missing/unreadable directories retry with 1/2/4/8/16/30-second backoff. Wake, manual
  Retry, and the routing setting trigger an immediate refresh. External screenshot
  location changes are picked up by the recovery check or wake. Replaced directory
  identities cause the file watch to be recreated.
- Initial history is silent. File identities, rather than a timestamp watermark,
  identify new captures. Equal or old timestamps, renames, atomic replacement and
  bursts are covered. A burst updates the strip but only its newest discovered
  capture controls notification/automatic copying.
- Newly discovered files must decode before publication. At most seven readiness
  checks run per scan. Incomplete files get up to six attempts with backoff; changed
  content can restart attempts. Completing an older pending file never replaces the
  newer capture's clipboard notification.
- Thumbnail decoding uses one background worker. Cancelled view tasks skip queued
  work and discard completed obsolete images, keeping rapid strip changes from
  launching unbounded concurrent decodes.
- Clipboard conversion has one active job and one pending latest job. New requests,
  stop/rebind, or disabling automatic copying invalidate older commits. A clipboard
  change by the user while conversion runs is preserved. PNG data is kept as PNG,
  and decoded image data is also prepared as TIFF before the main-thread commit.
- Image reads are limited to 128 MiB and raster decoding to 100 million pixels.
  PDF previews/copies rasterize the first page (copies at up to 4096 pixels on the
  long edge). Unsupported/corrupt/oversized images never claim successful copying.

Normal named screenshots do not depend on Spotlight. Localized/renamed screenshots
without a recognized prefix still depend on macOS exposing the screen-capture flag;
indexing delays can delay recognition. A background scan still consumes CPU and
filesystem I/O proportional to folder size. These changes remove UI blocking and
repeated metadata work; they do not make an arbitrary-sized folder free to scan.

## User-visible behavior

The banner initially says **Screenshot captured**. It changes to **Screenshot copied
to clipboard** only after a successful commit, and only if that screenshot's banner
is still displayed. Completion does not reopen a dismissed banner or replace a Codex
notification. Automatic copying being disabled or unsuccessful leaves capture feedback
truthful.

The screenshot tab retains the last successful strip during a read failure and shows
a recovery message and Retry action. Thumbnail tasks use file signatures so a file
replaced at the same URL refreshes; obsolete thumbnail tasks cannot overwrite newer
results.

Cleanup enumerates in the background, asks for confirmation, then moves only that
confirmed snapshot to Trash in the background. Files changed since confirmation are
skipped, new captures are excluded, and a moved/total result is displayed. Tests use
only disposable files and an injected trash operation.

## Verification

`ScreenshotPipelineTests` covers cache reuse/invalidation; silent history and strip
limits; equal/old timestamps; rename/replacement; burst and partial/corrupt files;
background execution and refresh coalescing; in-flight rebind/stop; native filesystem
events; permission loss/recovery; automatic missing-folder recovery; wake/location
changes; repeated start/stop descriptor counts; private-pasteboard success/failure,
latest-wins/cancellation/user changes; truthful banner text; PNG/JPEG/TIFF/PDF paths;
size bounds; symlinked screenshot directories; cancellation of thumbnail work;
a pixel-based hosted-view check that decoded content replaces the placeholder;
and cleanup snapshot boundaries.

```sh
swift test -c release --filter 'ScreenshotPipelineTests|ReleaseSafetyTests'
./scripts/benchmark-notch.sh --samples 30 --soak-seconds 60
```

The whole-app runner includes these regression tests, separate cold-start and cached
folder timings, a 5 ms main-actor heartbeat during a cold 10,000-file scan, simultaneous
Codex completion delivery/UI state changes, and a 60-second mixed workload when run
with the command above. It continues to exclude Claude. These are automated fixture
and native-service checks, not an OS capture/permission-dialog or physical sleep test.

Final validation: 20 screenshot regression tests passed in both normal release and
benchmark builds; the full benchmark passed 44 tests. See the final results in
[notch-performance.md](notch-performance.md). The 10K scan's main-actor heartbeat was
1.06 ms p95, while combined forced-render stress still showed 63 ms p95 scheduling
lateness. The latter remains an investigation item; this change is not a claim that
every Notch rendering or hardware scenario is now performance-validated.
