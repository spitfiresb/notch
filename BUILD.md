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

The app has **no Dock icon and no menu bar item** (`LSUIElement`). After `run`, look at the top-centre of your screen — you'll see the black notch. Hover it to open. Quit it from the gear (Settings) tab, or `./build.sh kill`.

## When you must open Xcode

You shouldn't need to for day-to-day work. You only need it for:

- **Adding/removing Swift Package dependencies** — edit `Package.swift` (works from the terminal too: `swift package resolve`).
- Nothing else here requires Xcode — there's no `.xcodeproj`, no asset catalog, no entitlements file. New `.swift` files under `Sources/Notch/` are picked up automatically by SwiftPM.

## Permissions / why grants reset

`build.sh` ad-hoc-signs the app (`codesign --sign -`). The signature's identity changes on
every rebuild, so macOS may forget Accessibility / Automation grants after a rebuild. That's
fine for development — just re-run the in-app setup (gear tab → "Re-run setup…"). For a
stable build, sign with a real (even self-signed) certificate instead of `-`.

## Architecture (quick map)

- `main.swift` / `AppDelegate.swift` — AppKit entry point, owns the panel and onboarding window.
- `AppEnvironment.swift` — observable app state (`NotchState` + the three services), injected into SwiftUI.
- `Window/NotchPanel.swift` — borderless floating `NSPanel` pinned top-centre; `ScreenMetrics` + `NotchShape`.
- `Views/NotchRootView.swift` — the blob, hover/expand behaviour, tab bar, collapsed peek.
- `Views/Tabs.swift` — Music / Screenshots / Clipboard / Settings tab UIs.
- `Views/OnboardingView.swift` — first-run permissions walkthrough.
- `Services/NowPlaying.swift` — `MediaRemoteBridge` (private framework, system "Now Playing") with a
  Spotify-via-Apple-Events fallback for when macOS blocks MediaRemote for un-entitled apps.
- `Services/ScreenshotWatcher.swift` — Spotlight query for `kMDItemIsScreenCapture` files.
- `Services/ClipboardWatcher.swift` — polls `NSPasteboard` for a short history.
- `Services/Permissions.swift` — TCC checks + System Settings deep links used by onboarding.
