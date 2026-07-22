<div align="center">

# Notch

**A Dynamic Island for your Mac's notch — built from scratch in Swift.**

Hover the notch and it blooms into a music player. Take a screenshot and it pops in with a toast. When you're not looking at it, it costs ~0% CPU.

![Notch opening on hover](docs/assets/demo.gif)

</div>

---

## What it does

<table>
<tr>
<td width="50%">

**Collapsed** — a slim pill hugging the hardware notch. Album art on the left, six audio-reactive bars dancing to whatever's playing on the right. The menu bar underneath stays fully clickable.

</td>
<td>

![Collapsed pill](docs/assets/collapsed.png)

</td>
</tr>
<tr>
<td>

**Expanded** — hover and the pill morphs into a player: artwork, title, a draggable scrubber, and transport controls. The album art and bars *travel* between the two layouts (`matchedGeometryEffect`), so opening feels like one continuous shape-shift rather than a swap.

</td>
<td>

![Expanded player](docs/assets/expanded.png)

</td>
</tr>
</table>

- **Now Playing, from anywhere** — reads the system's Now Playing data (the same source Control Center uses), with a Spotify Apple-Events fallback for macOS versions that lock MediaRemote down. Play/pause, skip, and seek from the notch.
- **Real audio visualization** — a CoreAudio process tap feeds six log-spaced bandpass filters (80 Hz → 7 kHz); each bar is a real frequency band with its own attack/release envelope. Not a canned animation.
- **Screenshots tab** — watches for new screenshots, pops a toast, optionally copies them straight to the clipboard and routes them into a tidy folder. Swipe horizontally on the trackpad to switch tabs.

  ![Screenshot toast and screenshots tab](docs/assets/screenshot-demo.gif)

  *Take a screenshot → the notch pops a "copied to clipboard" toast; hover it to reveal the recent-screenshots strip.*
- **Stays out of the way** — no Dock icon, no menu bar item. It pins itself across every Space (including full-screen apps) and ducks off-screen when Mission Control or App Exposé takes over.

## Why it's interesting under the hood

This is not a menu-bar-app template. A few of the problems it solves:

**Living on every Space.** A normal floating panel vanishes during Space swipes and full-screen transitions. Notch attaches its panel to a private CGS overlay space so it stays glued to the top of the screen through trackpad Space swipes, full-screen apps, and Mission Control — and retracts into the "bezel" with a spring animation when a system overlay needs the screen.

**Real-time audio analysis on a budget.** macOS 14.2's `AudioHardwareCreateProcessTap` provides a public way to tap the system mixdown. The tap runs six direct-form-I biquads per sample on the realtime IO thread, publishes RMS-per-band through a lock-protected snapshot, and a 60 Hz main-thread tick shapes it through per-band dB windows and asymmetric envelope followers. The result: bars that visibly *travel* instead of teleporting.

**Costing nothing at idle.** Every loop in the app is gated or event-driven: the audio tap exists only while music plays, hover detection rides mouse-moved events instead of a poll, UI publishes are skipped when nothing visibly changed, and Spotify updates arrive via distributed notification. Idle CPU is ~0% (down from ~15% in an earlier naive version — see [PR #1](https://github.com/spitfiresb/notch/pull/1) for the hunt).

**First-class trackpad feel.** Two-finger horizontal swipes switch tabs (with haptic ticks), respecting natural-scrolling direction, and a gesture monitor keeps the panel from fighting the system during live Space swipes.

## Getting started

```bash
git clone https://github.com/spitfiresb/notch.git
cd notch
./build.sh run
```

Requires **macOS 14.2+** (for the audio tap; everything else degrades gracefully) and Xcode command-line tools. No Xcode project — it's a plain Swift Package driven by `build.sh`. See [BUILD.md](BUILD.md) for the full build/run/debug workflow.

On first launch an onboarding window walks through the permissions it wants:

| Permission | Used for | Optional? |
|---|---|---|
| Audio capture | The dancing bars (system audio tap) | Yes — bars fall back to a synthesized wiggle |
| Automation (Spotify) | Track info + controls when MediaRemote is unavailable | Yes — if you don't use Spotify |
| Screenshot folder access | The screenshots tab & toasts | Yes |

## Architecture

```
Sources/Notch/
├── main.swift, AppDelegate.swift      AppKit entry point; hover/overlay watchers
├── AppEnvironment.swift               Observable app state, service lifecycle & gating
├── Window/
│   ├── NotchPanel.swift               Borderless panel, NotchShape, swipe detection
│   └── SettingsWindowController.swift
├── Views/
│   ├── NotchRootView.swift            The blob: collapsed peek ↔ expanded morph
│   ├── Tabs.swift                     Music & Screenshots tabs, scrubber
│   ├── OnboardingView.swift           First-run permissions walkthrough
│   └── SettingsView.swift
└── Services/
    ├── AudioMeter.swift               CoreAudio process tap → 6-band levels
    ├── NowPlaying.swift               MediaRemote bridge + Spotify fallback
    ├── ScreenshotWatcher.swift        Screenshot detection & routing
    ├── SpaceAttacher.swift            Private CGS space pinning
    ├── TrackpadGestureMonitor.swift   Live-gesture detection
    ├── Permissions.swift              TCC checks & System Settings deep links
    └── SettingsStore.swift            Persisted preferences
```

A more detailed map lives in [BUILD.md](BUILD.md).

## Status

Personal project, actively developed. Tested on Apple Silicon, macOS 26. Issues and ideas welcome.
