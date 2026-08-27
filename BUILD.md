# Building & running Notch

This is a plain Swift Package — **no Xcode project**. Everything goes through `./build.sh`.

## Commands

| Command            | What it does |
|--------------------|--------------|
| `./build.sh`       | Compile and assemble `build/Notch.app` |
| `./build.sh run`   | Compile, kill any running copy, and launch the app |
| `./build.sh kill`  | Quit the running app |
| `./build.sh clean` | Remove `.build/` and `build/` |
| `./build.sh logs`  | Tail the app's log file (`~/Library/Logs/Notch/notch.log`) |

Add `CONFIG=release` for an optimized build, e.g. `CONFIG=release ./build.sh run`.

The app has **no Dock icon and no menu bar item** (`LSUIElement`). After `run`, look at the top-centre of your screen — you'll see the black notch. Hover it to open; swipe horizontally with two fingers to switch tabs. There's no in-app quit — use `./build.sh kill`.

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
- `Services/ClaudeSessions.swift` — `ClaudeSessionStore`: tails the spool
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

## Debugging Claude sessions

- Events land in `~/Library/Application Support/Notch/claude-events.jsonl`; every one is also
  logged (`./build.sh logs`). Notch truncates the spool after replaying it on launch.
- To fake a finished session without running Claude, append a `Stop` event line with a
  made-up pid (e.g. `"pid":99999`) to the spool, then a `SessionEnd` line to clear the row.
- Toast variants (`SessionToast.Kind`): complete, permission, question, failed. Attention
  callbacks are muted during the launch replay so a backlog doesn't fire a burst of toasts.
- Claude Code hot-reloads hooks, so toggling the Settings switch affects sessions that are
  already running.
- The README's Claude captures (`docs/assets/claude-*.png`, `clawd-*.gif`) are real: the
  stills are `screencapture -R` of the notch region (the panel sits at x≈570, 300 pt wide)
  with a live session, and the GIFs are `screencapture -V` recordings cut with ffmpeg while
  fake `Stop` / `PermissionRequest` lines were appended to the spool as above.
