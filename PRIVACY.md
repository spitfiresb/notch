# Privacy and local data

Notch runs locally. It has no analytics SDK, advertising, account service,
crash-upload service, or automatic update check. “Copy app info” copies only
Notch's version/build, macOS version, and CPU architecture. Nothing is sent
when you use that button.

## What the features access

- **Music:** system Now Playing information and, when available, Spotify
  automation. The optional audio visualizer processes audio in memory; it
  does not save audio recordings. Artwork may be downloaded from the URL
  supplied by the player.
- **Screenshots:** reads recent captures in your configured screenshot folder.
  Automatic clipboard copying is on by default and can be disabled. Choosing
  screenshot routing changes macOS's save location; disabling it restores
  the previous location when Notch still owns the setting. Cleanup is an
  explicit, confirmed move to Trash.
- **Agent sessions:** Claude Code and Codex monitoring are on by default.
  Notch reads local process information and session records, including project
  paths, prompts, tool activity and reply snippets, to display them. These
  records are not uploaded. Claude integration adds its own hook entries to
  local Claude settings and backs up that file before changes. Disabling it
  removes only Notch's entries. Codex monitoring does not install hooks.
- **Spotify Library:** optional OAuth with PKCE using your own client ID.
  Spotify receives the sign-in and API requests needed to read or modify your
  library when you use those features. A temporary callback listener binds
  only to `127.0.0.1:8888` during login. Refresh tokens are in macOS Keychain;
  the playlist index is on disk. Disconnect clears the token and index.
- **Links:** opening Releases, Privacy, Spotify Dashboard or Report an issue
  opens the corresponding website in your browser, subject to that site's
  privacy policy. Notch does not attach diagnostics to those links.

## Local storage

| Location | Contents |
| --- | --- |
| `~/Library/Preferences/com.spitfiresb.notch.plist` | Preferences, setup state, custom Spotify client ID, previous screenshot location |
| `~/Library/Application Support/Notch/` | Spotify index, Claude hook script/event spool, Claude settings backups; legacy Codex integration files may remain after upgrades |
| `~/Library/Logs/Notch/notch.log` and `.old` | Operational diagnostics; each new log file is capped at 5 MB and owner-readable/writable |
| Keychain service `Notch.Spotify`, account `refresh-token` | Spotify refresh token |
| `~/.claude/settings.json` (or `CLAUDE_CONFIG_DIR`) | Notch hook entries alongside your existing settings |

The hook spool and settings backups can contain sensitive session content or
configuration. Treat the entire Application Support folder as private. Hooks
can continue appending events while Notch is closed; turn the integration off
before uninstalling. The running app consumes/truncates the spool, but it is
not a durable transcript archive.

New operational logs omit prompts, replies and token fragments. Older logs
from development builds may still contain these: inspect or delete old logs
before sharing. Other error diagnostics can include local paths. Never attach
session spools, settings backups or Keychain contents to a public issue.

## Uninstall and optional cleanup

1. In Settings, turn off launch at login, Claude monitoring and Codex monitoring.
   If a hook-removal error appears, resolve it before removing the app.
2. Disconnect Spotify. If screenshot routing is enabled, turn it off to restore
   the previous save location. Notch preserves a location changed externally.
3. Quit Notch, then move `/Applications/Notch.app` to Trash.
4. Optionally remove the **Notch** Application Support and Logs folders above.
   Remove preferences with `defaults delete com.spitfiresb.notch` while the app
   is closed. Do not remove Claude/Codex transcripts or their settings files.
5. If you could not disconnect, remove only the `Notch.Spotify` credential in
   Keychain Access. You may also remove Notch from macOS Privacy & Security
   permission lists and Login Items.

Older development builds disabled macOS's floating screenshot thumbnail. This
build leaves that preference alone; restore it through Screenshot (Shift-Cmd-5)
→ Options → Show Floating Thumbnail if desired.
