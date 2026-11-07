#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?app bundle required}"
manifest="${2:?tested source manifest required; use ./build.sh release}"
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[1-9][0-9]*$ ]] || {
    echo 'Use a numeric x.y.z version and positive integer build in Resources/Info.plist.' >&2; exit 1;
}
mkdir -p build/releases
name="Notch-${version}-${build}-arm64"
destination="build/releases/$name"
[[ ! -e "$destination" ]] || { echo "Already exists: $destination (move it aside or bump the build)." >&2; exit 1; }
work=$(mktemp -d "$PWD/build/releases/.package.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/staging" "$work/artifacts"
cp "$manifest" "$work/artifacts/SOURCE-SHA256SUMS"
ditto "$app" "$work/staging/Notch.app"
ln -s /Applications "$work/staging/Applications"
cp docs/INSTALL.txt "$work/staging/READ ME FIRST.txt"
cp PRIVACY.md "$work/staging/PRIVACY.txt"
if [[ -f LICENSE ]]; then cp LICENSE "$work/staging/LICENSE.txt"; fi
hdiutil create -volname "Notch $version" -srcfolder "$work/staging" -format UDZO -ov "$work/artifacts/$name.dmg"
scripts/verify-release.sh "$work/artifacts/$name.dmg"
(
    cd "$work/artifacts"
    shasum -a 256 "$name.dmg" > SHA256SUMS
)
{
    echo "Notch $version (build $build)"
    echo "Architecture: arm64; minimum macOS: 14.2"
    echo "Commit: $(git rev-parse HEAD)"
    if [[ -n $(git status --porcelain) ]]; then
        echo 'Source state: DIRTY — local candidate; commit and rebuild before public release.'
    else
        echo 'Source state: clean'
    fi
    echo "Built at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    swift --version 2>&1
    echo "SDK: $(xcrun --show-sdk-version)"
    echo 'Validation: swift test, bundle seal, arm64, deployment target, DMG mount/content checks.'
    echo 'Signing: ad-hoc only; not notarized. Manual acceptance checks remain in PUBLISH.md.'
} > "$work/artifacts/BUILD-INFO.txt"
mv "$work/artifacts" "$destination"
echo "→ release candidate: $destination"
