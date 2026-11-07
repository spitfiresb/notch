# Building & running Notch

This is a plain Swift Package — **no Xcode project**. Everything goes through `./build.sh`.

## Commands

| Command            | What it does |
|--------------------|--------------|
| `./build.sh`       | Compile and assemble `build/Notch.app` |
| `./build.sh run`   | Compile, kill any running copy, and launch the app |
| `./build.sh test` | Run Swift tests and offscreen render checks |
| `./build.sh release` | Test, build optimized arm64 app, generate and verify a DMG + checksum |
| `./build.sh verify FILE.dmg` | Mount and verify a packaged artifact without launching it |
| `./build.sh kill`  | Quit the running app |
| `./build.sh clean` | Remove `.build/` and `build/` |
| `./build.sh logs`  | Tail the app's log file (`~/Library/Logs/Notch/notch.log`) |

Add `CONFIG=release` for an optimized build, e.g. `CONFIG=release ./build.sh run`.

The app has **no Dock icon and no menu bar item** (`LSUIElement`). After `run`, look at the top-centre of your screen — you'll see the black notch. Hover for controls, then click to expand; swipe horizontally with two fingers to switch tabs. Quit from Settings → About & support, or use `./build.sh kill`. Reopening the installed app brings up Settings.

## When you must open Xcode

You shouldn't need to for day-to-day work. You only need it for:

- **Adding/removing Swift Package dependencies** — edit `Package.swift` (works from the terminal too: `swift package resolve`).
- Nothing else here requires Xcode — there's no `.xcodeproj`, no asset catalog, no entitlements file. New `.swift` files under `Sources/Notch/` are picked up automatically by SwiftPM.

## Permissions / why grants reset

`build.sh` ad-hoc-signs the app (`codesign --sign -`). The signature's identity changes on
every rebuild, so macOS may forget Audio-capture / Automation grants after a rebuild. That's
fine for development — the onboarding flow (shown on first launch) walks through re-granting.
For a stable build, sign with a real (even self-signed) certificate instead of `-`.

Two consequences worth knowing during development:

- **Keychain prompt on every rebuild.** The Spotify refresh token lives in the keychain under
  `Notch.Spotify`, and a new ad-hoc signature means a new "Notch wants to use your keychain" dialog
  on launch. The app doesn't finish starting until you click *Allow* — if the notch hasn't appeared
  after `./build.sh run`, look for that dialog. `spotify: synced` in the log means it's through.
- **Accessibility doesn't reset from the Settings toggle.** Flipping Notch off/on in
  System Settings → Accessibility doesn't clear a stale ad-hoc grant. To start clean:
  `tccutil reset Accessibility com.spitfiresb.notch`.

Freshly built binaries also get a one-time XProtect/Gatekeeper scan on first launch — a brief
CPU burst right after `./build.sh run` is the scanner, not the app.

## Architecture (quick map)

- `App/main.swift` / `App/AppDelegate.swift` — AppKit entry point; owns the panel, hover watcher
  (mouse-moved event monitors), Mission Control detection, and Space re-attachment.
- `App/AppEnvironment.swift` — observable app state (`NotchState` + services), injected into SwiftUI;
  gates the audio meter so the system tap only runs while music is playing.
- `Window/NotchPanel.swift` — borderless floating `NSPanel` pinned top-centre; `ScreenMetrics`,
  `NotchShape`, and two-finger-swipe tab switching.
- `Window/SettingsWindowController.swift` — standalone settings window (opened from the gear in
  the expanded notch).
- `Views/NotchRootView.swift` — the blob: collapsed peek ↔ expanded morph, toasts (screenshot +
  Claude session), the Claude spinner beside the bars. `Views/DancingBars.swift` is the six
  audio-reactive bars it shares with the collapsed peek.
- `Views/Music/` — the Music tab, one type per file: `MusicTabView`, `TransportButtons`
  (⏮ ⏯ ⏭), `MusicProgressLine` (scrubber), `MarqueeText` (Spotify-style scrolling for titles that
  don't fit), `SaveButton` (+ confetti burst), and the expanding `SavedInPanel` playlist list.
- `Views/Screenshots/` — `ScreenshotTabView` (thumbnail strip), `ScreenshotToastView` (copied
  banner), and `ScreenshotImage` (thumbnail loading / relative timestamps).
- `Views/Claude/` — `SessionsCorner` (spinner parked bottom-right, unfolds the panel),
  `SessionsPanel` (one row per `claude` process), `ClawdSprite` (the pixel mascot), and
  `SessionToastView` (Clawd's choreographed banners).
- `Views/Shared/` — `EmptyTab` placeholder and the `Haptics` helper.
- `Views/OnboardingView.swift` — first-run walkthrough: welcome → permissions → optional Spotify
  Library → done.
- `Views/SettingsView.swift` — launch-at-login, Claude Code sessions toggle, screenshot routing /
  clipboard / cleanup, and the Spotify connect / bring-your-own-client-ID controls.
- `PermissionPrompt/` — the guided-permissions overlay: `PermissionPromptAssistant` decides
  between the native consent prompt and opening System Settings; `PermissionOverlayWindow` floats
  a non-activating panel next to the privacy pane (`PermissionDragRow` / `PermissionToggleRow`
  animate what to do); `SettingsWindowLocator` tracks the Settings window without Screen Recording.
- `Services/AudioMeter.swift` — CoreAudio process tap → six bandpass-filtered levels driving the bars.
- `Services/NowPlaying.swift` — `MediaRemoteBridge` (private framework, system "Now Playing") with a
  Spotify-via-Apple-Events fallback (event-driven via Spotify's `PlaybackStateChanged` notification).
- `Services/SpotifyLibrary.swift` — Spotify Web API client: PKCE OAuth with a loopback redirect,
  a local snapshot-diffed mirror of your playlists, and like / add-to-playlist writes.
- `Services/ClaudeHooks.swift` — writes `~/Library/Application Support/Notch/claude-hook.sh` and
  adds/removes the matching hook entries in `~/.claude/settings.json` (only entries pointing at our
  script are ever touched).
- `Services/AgentSessions.swift` — `AgentSessionStore`: shared Claude/Codex model and state machine; reads provider spools
  (`~/Library/Application Support/Notch/claude-events.jsonl`) via a vnode source + 1 s poll,
  replays it on launch, folds events into per-session state, dedupes by pid, reaps dead
  processes, and focuses the session's Terminal tab (by tty) or VS Code window (by title).
- `Services/ScreenshotWatcher.swift` — screenshot detection, toast + optional clipboard copy,
  and "clean up" (trash every screenshot in the folder).
- `Services/SpaceAttacher.swift` — pins the panel to every Space via private CGS calls.
- `Services/TrackpadGestureMonitor.swift` — tracks live trackpad gestures so Space swipes aren't fought.
- `Services/Permissions.swift` — TCC checks + System Settings deep links used by onboarding.
- `Services/SettingsStore.swift` — persisted user preferences; also owns the
  `com.apple.screencapture.location` routing to `~/Pictures/Screenshots`.
- `Services/DebugLog.swift` — `notchLog` helper; writes `~/Library/Logs/Notch/notch.log` (`./build.sh logs`).

## Whole-app performance

Run `./scripts/benchmark-notch.sh` for the optimized fixture suite and combined soak (Claude excluded). Use `--samples 30 --soak-seconds 60` for a longer run. It snapshots sources, retains raw metrics/render captures, and reports live checks as untested. See [whole-app benchmark protocol](docs/notch-performance.md) for coverage, budgets, and `sample-notch.sh` live CPU/memory collection.

## Debugging Claude sessions

- Events land in `~/Library/Application Support/Notch/claude-events.jsonl`; every one is also
  logged (`./build.sh logs`). Notch truncates the spool after replaying it on launch.
- To fake a finished session without running Claude, append a `Stop` event line with a
  made-up pid (e.g. `"pid":99999`) to the spool, then a `SessionEnd` line to clear the row.
- Toast variants (`SessionToast.Kind`): complete, permission, question, failed. Attention
  callbacks are muted during the launch replay so a backlog doesn't fire a burst of toasts.
- Claude monitoring starts before hook setup. Malformed/unreadable settings do not stop the
  spool reader or independent transcript reader. Setup/cleanup failures retry every 30 seconds.
  Existing settings bytes are backed up before valid edits; malformed data is never replaced.
- `ClaudeSessionMonitor.swift` follows exact session IDs from hooks, open transcript/debug files,
  or process arguments, with bounded 2 MiB incremental reads and silent initial replay. It
  retains readers across temporary discovery failures and handles transcript inode replacement.
  It does not guess session identity by choosing the newest chat in a shared project directory.
- A process without readable session evidence shows `detecting`; discovery continues automatically.
  Permission/subagent detail still relies on hooks. A silent process is not proof of a completed
  or interrupted turn, so the previous network-traffic heuristic is no longer used.
- `ClaudeReliabilityTests.swift` covers configuration preservation/backups, retry recovery,
  shell quoting, transcript replay/replacement, exact descriptor discovery, fallback arbitration,
  explicit interruption, and process-only rows. Tests use temporary settings, not personal files.
- The README's Claude captures (`docs/assets/claude-*.png`, `clawd-*.gif`) are real: the
  stills are `screencapture -R` of the notch region (the panel sits at x≈570, 300 pt wide)
  with a live session, and the GIFs are `screencapture -V` recordings cut with ffmpeg while
  fake `Stop` / `PermissionRequest` lines were appended to the spool as above.

## Debugging Codex sessions

- Performance: run `./scripts/benchmark-codex.sh` for an opt-in release benchmark of discovery, idle/active scans, heavy output and bounded replay. See [benchmark methodology and metrics](docs/codex-performance.md); JSON reports go to `.build/benchmarks/`.
- Claude and Codex monitoring default to on; explicit opt-outs remain off. Codex discovery does not require hooks, trust changes, shell configuration, or restarting existing terminal sessions.
- `CodexSessionMonitor.swift` uses libproc to enumerate native Codex processes and their open `rollout-*.jsonl` file descriptors. It reads metadata and a bounded 2 MiB tail on initial discovery, then only appended bytes. Discovery and parsing run on a serial utility queue every second, outside the UI thread.
- Each rollout maps to its actual owning PID. Multiple terminals in the same cwd remain separate. When a CLI retains older rollout descriptors after a resume, only its most recently modified root rollout is shown. Subagent metadata is excluded. Closed files/processes remove their rows; transient fd-inspection failures retain existing rows.
- `task_started`, tool call/result records, `task_complete`, and `turn_aborted` feed the shared state machine. Initial replay is silent. Turn IDs prevent stale completions and late tool results from reviving an interrupted turn. `CodexContext` and `CodexPrompt` are internal normalized events, not Codex hooks.
- `CodexHooks.swift` remains for migration cleanup and tests. On startup Notch removes only its own old entries from `hooks.json`; it does not write trust records or alter other hooks/configuration. Monitoring proceeds even if cleanup fails.
- `swift test --filter 'ClaudeHooksTests|ClaudeTranscriptTests|SessionRecoveryTests|CodexRolloutTests|CodexSessionTests|CodexHooksTests|SessionSpoolTests|InterruptDetectionTests'` covers real rollout shapes, bounded/silent initial replay, partial/malformed lines, file-descriptor discovery, same-folder sessions, resuming, cleanup, interruption, and Claude regression checks.
- Live verification: launch Notch while Codex CLI is already running. Inspect the sessions panel and operational `sessions:` entries in `~/Library/Logs/Notch/notch.log`; send a prompt and check the mint indicator and completion toast. No `/hooks` step should be needed.
- Compatibility: verified against native CLI 0.153.4. The local rollout schema is an implementation detail, so future versions require compatibility checks. Clients that do not hold a readable rollout open are not detected. Permission dialogs, compaction progress, and subagent counts are not guaranteed by the rollout format; terminal multiplexers and exact desktop-thread focus remain limited.

## Release builds

See [PUBLISH.md](PUBLISH.md) for the build pipeline and manual acceptance matrix.
Version/build live in `Resources/Info.plist`. The app icon is original vector
artwork rendered by `scripts/generate-icon.swift`; all sizes are bundled in an
ICNS. Release builds target arm64 and macOS 14.2. Packaging checks the executable's
actual deployment target against the plist.

New logs omit session text and Spotify credentials and rotate during use.
Do not attach old development logs without reviewing them. Privacy, local data
and uninstall instructions are in [PRIVACY.md](PRIVACY.md).
