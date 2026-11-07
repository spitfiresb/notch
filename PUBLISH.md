# Preparing a download

The no-fee release pipeline is implemented. A local candidate is **not yet a
public-release sign-off**: complete the manual acceptance matrix below on the
exact artifact before putting its URL on a website. No paid service, Developer
ID, notarization, Sparkle account or Homebrew installation is needed to build.

## Build a candidate

Requirements: Apple Silicon Mac, Xcode command-line tools with Swift 6 or later.
The downloadable app requires Apple Silicon and macOS 14.2 or later.

`Resources/Info.plist` is the version/build source of truth. Update
`CFBundleShortVersionString` (x.y.z) and increment `CFBundleVersion` for each
published build. `Package.swift` and the plist both declare macOS 14.2; the
artifact verifier checks the actual binary's deployment target too.

```sh
./build.sh release
```

This runs the tests, compiles an optimized arm64 executable, generates the
original app icon, assembles and ad-hoc seals the bundle, and makes a compressed
DMG containing Notch, an Applications shortcut, installation help and privacy
notes. It mounts the DMG read-only to verify its contents, architecture, runtime
dependencies and bundle integrity. It does not launch or install the app.

Output is `build/releases/Notch-VERSION-BUILD-arm64/`:

- `Notch-VERSION-BUILD-arm64.dmg`
- `SHA256SUMS` (verify from that directory with `shasum -a 256 -c SHA256SUMS`)
- `BUILD-INFO.txt` (commit, clean/dirty source status, compiler, SDK and checks)
- `SOURCE-SHA256SUMS` (exact build/test/packaging input hashes, including new files)

Existing version/build output is never overwritten. Move an earlier local
candidate aside, or bump the build number. `./build.sh verify path/to/file.dmg`
repeats the integrity checks. A dirty working tree is allowed for local testing,
but is explicitly marked: commit the reviewed code and rebuild before release.
The pipeline is repeatable, not a claim of byte-for-byte reproducible DMGs.
It rejects source edits made during testing/building so the artifact matches
the tested inputs.

## Completed without paid services

- Release/test/verify commands, checksums and build provenance.
- Original icon at macOS icon sizes, installed version and sanitized app-info copy.
- DMG/translocation launch guard before services start; reopening finds Settings;
  a second installed copy redirects to the running app.
- Login startup is opt-in and failures are visible. Existing registration is kept.
- Setup can be deferred; the setup text describes actual features.
- Screenshot routing remembers the original location and preserves external
  changes; startup no longer changes the system screenshot thumbnail setting.
- Log files rotate during use with restricted permissions. Session text and
  Spotify token fragments are omitted from new operational logs.
- Spotify uses only the user's client ID; disconnect cancels pending login and
  clears the index; the OAuth listener binds to loopback only.
- Privacy, installation, manual-update and uninstall instructions; issue template.
- GitHub workflow for tests and downloadable candidate artifacts. It runs only
  for a public repository to avoid paid private-repository minutes. No publishing
  or release-write permission is granted.

## Manual acceptance: required before the public link

Record the version, build, macOS, hardware and result in `docs/RELEASE-QA.md`.
Automated tests do not stand in for TCC prompts, a real Finder install or display
hardware. Use a fresh macOS user or a separate test Mac; do not reset permissions
on your everyday account just to run this checklist.

- [ ] **Fresh install:** download through a browser (quarantine intact), open DMG,
  drag to Applications, eject, launch, complete or defer setup, quit and reopen.
  Launching inside the DMG should show installation help without installing hooks.
- [ ] **Permissions:** independently deny/grant Accessibility, Spotify Automation,
  screenshot-folder access and audio capture. No crash or stuck setup. Recover via
  Settings. Verify first-run behavior with Spotify absent and with no CLI tools.
- [ ] **OS coverage:** test macOS 14.2 (minimum), 15 and 26 before claiming those
  releases work. Private MediaRemote/SkyLight/Multitouch APIs make this essential.
  Record any untested versions explicitly in release notes.
- [ ] **Displays:** built-in notch; non-notched external main display; switch main
  display; unplug monitor; sleep/wake; full screen, Spaces and Mission Control.
  Check top, left and right docks remain visible and clickable.
- [ ] **Music:** play/pause/skip/seek with supported players; denied audio permission
  leaves usable controls; no player and network offline stay responsive.
- [ ] **Spotify Library (optional):** your own client ID; success, denial, wrong
  redirect URI, occupied port 8888, disconnect during login, expired/revoked token,
  offline/rate-limit behavior. The rest of the app works without this feature.
- [ ] **Screenshots:** default and custom folder, routing on/off, clipboard on/off,
  permission denial, cleanup cancel/confirm and restore from Trash. Confirm other
  files are untouched and the prior screenshot folder is restored.
- [ ] **Sessions:** no tools installed; existing and new Claude/Codex sessions;
  complete/interrupt/permission/question; disable both integrations; verify other
  Claude hooks/settings survive. Review any monitoring errors.
- [ ] **Upgrade:** install over an earlier build while quit; settings/opt-outs remain;
  renew any needed permissions; no duplicate app or login item.
- [ ] **Long run:** Activity Monitor at idle and with multiple active sessions;
  check CPU, memory growth, sleep/wake and logs after an extended session. No
  universal idle-CPU promise based only on a development machine.
- [ ] **Uninstall:** follow PRIVACY.md; no Notch hooks or login item left enabled;
  screenshot files and unrelated settings survive.
- [ ] **Rights and presentation:** choose a source/distribution license; review
  third-party names, mascots and screenshots for publication. The new app icon is
  original code-drawn artwork; this does not grant rights to third-party assets.

## Publishing once acceptance passes

1. Commit the reviewed source, increment the build if needed, and rebuild from a
   clean checkout. Review the artifact and `BUILD-INFO.txt`.
2. Tag that commit `vVERSION`. Create a **draft** GitHub Release, describe tested
   OS/hardware, limitations and known issues; attach DMG, SHA256SUMS and build info.
3. Download and verify the attached artifact. Publish the release when ready.
4. Add a download link to that release (or its asset) in the README/site. State
   Apple Silicon, macOS 14.2+, manual updates and the first-open steps beside it.

Until that release exists, docs link to the Releases page without claiming a
public download is available. No release has been published by this work.

Updates are manual for v0.1: Settings → Releases & updates opens GitHub. A
throttled update notification, auto-updater, universal Intel build, Homebrew tap,
per-turn token counts and new UI features are optional follow-ups, not blockers
for a downloadable preview.

## First-open and service constraints

This build is ad-hoc signed and not notarized. Follow Apple's documented
[Open Anyway steps](https://support.apple.com/en-us/102445); do not promise
that Homebrew bypasses Gatekeeper. Permissions may need renewal after updates.
Paid signing work is intentionally deferred.

[GitHub standard hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
are free for public repositories; private repositories have usage allowances and
potential charges, so the checked-in workflow skips them. Local release builds
have no hosted-service cost.

Spotify Library remains optional. Its own
[development-mode restrictions](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)
include Premium for the app owner. Users who do not want that can skip library
integration; Notch's basic playback and other features do not require it.
