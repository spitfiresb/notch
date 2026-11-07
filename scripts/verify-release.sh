#!/usr/bin/env bash
set -euo pipefail
dmg="${1:?DMG path required}"
hdiutil verify "$dmg"
mount_dir=$(mktemp -d /tmp/notch-dmg-check.XXXXXX)
attached=false
cleanup() {
    if $attached; then hdiutil detach "$mount_dir" >/dev/null || true; fi
    rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_dir" >/dev/null
attached=true
app="$mount_dir/Notch.app"
plutil -lint "$app/Contents/Info.plist"
codesign --verify --strict "$app"
[[ $(lipo -archs "$app/Contents/MacOS/Notch") == arm64 ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") == com.spitfiresb.notch ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist") == 14.2 ]]
[[ $(xcrun vtool -show-build "$app/Contents/MacOS/Notch" | awk '/minos/ {print $2}') == 14.2 ]]
[[ -s "$app/Contents/Resources/Notch.icns" ]]
[[ -L "$mount_dir/Applications" && $(readlink "$mount_dir/Applications") == /Applications ]]
[[ -s "$mount_dir/READ ME FIRST.txt" && -s "$mount_dir/PRIVACY.txt" ]]
# Runtime libraries must resolve from the OS or the bundle, never a developer's machine.
if otool -L "$app/Contents/MacOS/Notch" | tail -n +2 | awk '{print $1}' | /usr/bin/grep -Ev '^(/System/Library/|/usr/lib/|@rpath/|@executable_path/|@loader_path/)'; then
    echo 'Unexpected external runtime dependency.' >&2; exit 1
fi
echo '→ DMG integrity and contents verified (app not launched).'
