# Building & running Notch

This is a plain Swift Package — **no Xcode project**. Everything goes through `./build.sh`.

## Commands

| Command            | What it does |
|--------------------|--------------|
| `./build.sh`       | Compile and assemble `build/Notch.app` |
| `./build.sh run`   | Compile, kill any running copy, and launch the app |
| `./build.sh kill`  | Quit the running app |
| `./build.sh clean` | Remove `.build/` and `build/` |
| `./build.sh logs`  | Tail the app's `os_log` output |

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

Freshly built binaries also get a one-time XProtect/Gatekeeper scan on first launch — a brief
CPU burst right after `./build.sh run` is the scanner, not the app.

## Architecture (quick map)

- `main.swift` / `AppDelegate.swift` — AppKit entry point; owns the panel, hover watcher
  (mouse-moved event monitors), Mission Control detection, and Space re-attachment.
- `AppEnvironment.swift` — observable app state (`NotchState` + services), injected into SwiftUI;
  gates the audio meter so the system tap only runs while music is playing.
- `Window/NotchPanel.swift` — borderless floating `NSPanel` pinned top-centre; `ScreenMetrics`,
  `NotchShape`, and two-finger-swipe tab switching.
- `Window/SettingsWindowController.swift` — standalone settings window (opened from the gear in
  the expanded notch).
- `Views/NotchRootView.swift` — the blob: collapsed peek ↔ expanded morph, toast, dancing bars.
- `Views/Tabs.swift` — Music and Screenshots tab UIs, including the scrubber.
- `Views/OnboardingView.swift` — first-run permissions walkthrough.
- `Views/SettingsView.swift` — screenshot routing / clipboard toggles.
- `Services/AudioMeter.swift` — CoreAudio process tap → six bandpass-filtered levels driving the bars.
- `Services/NowPlaying.swift` — `MediaRemoteBridge` (private framework, system "Now Playing") with a
  Spotify-via-Apple-Events fallback (event-driven via Spotify's `PlaybackStateChanged` notification).
- `Services/ScreenshotWatcher.swift` — screenshot detection, toast + optional clipboard copy / folder routing.
- `Services/SpaceAttacher.swift` — pins the panel to every Space via private CGS calls.
- `Services/TrackpadGestureMonitor.swift` — tracks live trackpad gestures so Space swipes aren't fought.
- `Services/Permissions.swift` — TCC checks + System Settings deep links used by onboarding.
- `Services/SettingsStore.swift` — persisted user preferences.
- `Services/DebugLog.swift` — `notchLog` helper for `os_log` output (`./build.sh logs`).
