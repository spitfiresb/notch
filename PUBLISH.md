# Publishing Notch

Plan for taking Notch from a personal app to something strangers can download,
install, and use. This documents the decisions already made and the work
remaining. See `BUILD.md` for the day-to-day build workflow.

## Decisions

- **No Apple Developer fee (for now).** Ship ad-hoc signed. Users bypass
  Gatekeeper via System Settings → Privacy & Security → "Open Anyway", or
  avoid it entirely by installing through Homebrew. Revisit Developer ID +
  notarization if the app gets traction — it can be added later without
  changing anything else (users re-grant permissions once at the transition).
  - Known cost: TCC grants (Accessibility / Automation / audio) attach to the
    code signature, so with ad-hoc signing users may need to re-grant
    permissions after each update. Developer ID would fix this.
- **No Mac App Store.** Sandboxing would likely kill the system-audio capture
  and complicate the Apple Events automation.
- **Spotify: bring-your-own client ID.** Extended quota mode is closed to
  individuals (organizations with 250k+ MAU only), and development mode is
  capped at 5 allowlisted users. Since the OAuth flow is PKCE with a fixed
  loopback redirect (`http://127.0.0.1:8888/callback`), users can create their
  own free Spotify developer app and paste in their client ID. Caveat:
  dev-mode apps require the owner to have Spotify Premium.
- **Updates via GitHub Releases.** Lightweight launch-time check against the
  Releases API; no Sparkle / auto-install for v1.
- **Apple Silicon only.** Every notched Mac is arm64; a universal binary buys
  nothing.

## Work items

### 1. Spotify: bring-your-own client ID

- [x] Make the client ID a settings-backed value (UserDefaults-persisted on
      `SpotifyLibrary`), defaulting to the current hardcoded ID so the
      maintainer's build behaves exactly as today.
- [x] Settings: Spotify section gained a "Use your own Spotify app" area with
      the three-step walkthrough (create app → set redirect URI → paste
      client ID) and an Apply field; status/disconnect already existed.
- [x] 403s point at the walkthrough: both the Settings caption and the
      saved-in panel's denied message send the user to Settings → Spotify.
- [x] Degraded mode: the saved-in panel already showed a Connect prompt when
      unauthenticated; now-playing / playback control (Apple Events) works
      regardless — no Web API needed.
- [x] Changing the client ID disconnects: clears the keychain refresh token
      and the cached library index (tokens aren't valid across Spotify apps).

### 2. Release build & packaging

- [ ] `build.sh release` (or a separate `release.sh`): release config,
      version stamped into Info.plist from a single source of truth, ad-hoc
      sign, produce a DMG (`hdiutil` or `create-dmg`).
- [ ] App icon: design an `.icns`, add `CFBundleIconFile`. Without it,
      permission dialogs and Settings rows show a blank generic icon.

### 3. First-run hardening

- [x] Move `notchLog` from `/tmp/notch.log` to `~/Library/Logs/Notch/`
      (rotates at 5 MB since that directory survives reboots); chatty
      per-frame gesture logging removed.
- [ ] No-notch fallback: verify behavior on external displays and non-notch
      Macs — floating pill at top-center, or a clearly stated requirement. At
      minimum: no crash, nothing rendered off-screen.
- [ ] Test full onboarding on a fresh macOS account (zero TCC grants): every
      permission prompt appears; denial paths don't wedge the app.
- [ ] Audit for remaining personal assumptions (hardcoded paths, screenshot
      folder location, etc.).

### 4. Distribution & updates

- [ ] GitHub Release `v0.1.0` with the DMG attached.
- [ ] Optional: GitHub Action that builds and attaches the DMG on tag push,
      so releases are reproducible.
- [ ] Update check on launch (throttled ~daily) against the GitHub Releases
      API; subtle "update available" affordance linking to the release page.
- [ ] Homebrew cask in a personal tap (`spitfiresb/homebrew-tap`) so
      `brew install --cask spitfiresb/tap/notch` works — brew skips the
      quarantine flag, so this path has no Gatekeeper dialog at all.

### 5. Docs for strangers

- [ ] README install section: brew one-liner + DMG with an "Open Anyway"
      walkthrough (screenshot of the Settings dialog).
- [ ] Permissions section: what each TCC grant is for; note the re-grant
      caveat under ad-hoc signing.
- [ ] Spotify BYO-client-ID setup, mirrored from the in-app walkthrough.

## Suggested order

1–2 are the real code, 3 is mostly testing plus two small changes, 4–5 are
infrastructure and writing. Items needing a human: the fresh-account TCC test
and icon design direction.
