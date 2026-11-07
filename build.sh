#!/usr/bin/env bash
# Local builds and an offline, no-fee release pipeline. See PUBLISH.md.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Notch"
CONFIG="${CONFIG:-debug}"
APP="build/${APP_NAME}.app"

kill_app() { pkill -x "${APP_NAME}" >/dev/null 2>&1 || true; }

assemble() {
    local build_args=(-c "$CONFIG")
    if [[ "$CONFIG" == release ]]; then build_args+=(--arch arm64); fi
    swift build "${build_args[@]}"
    local bin_dir
    bin_dir=$(swift build "${build_args[@]}" --show-bin-path)
    rm -rf "${APP}"
    mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
    cp "${bin_dir}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
    cp Resources/Info.plist "${APP}/Contents/Info.plist"
    swift scripts/generate-icon.swift build/Notch.iconset
    iconutil -c icns build/Notch.iconset -o "$APP/Contents/Resources/Notch.icns"
    # No paid identity is used. Fail if the local integrity seal cannot be made.
    codesign --force --sign - "$APP"
    codesign --verify --strict "$APP"
    echo "→ built ${APP}"
}

case "${1:-build}" in
    build)  assemble ;;
    test) swift test ;;
    release)
        [[ $(uname -m) == arm64 ]] || { echo "Release builds require an Apple Silicon Mac." >&2; exit 1; }
        manifest=$(mktemp /tmp/notch-release-source.XXXXXX)
        trap 'rm -f "$manifest" "$manifest.after"' EXIT
        scripts/source-manifest.sh > "$manifest"
        swift test
        CONFIG=release
        assemble
        scripts/source-manifest.sh > "$manifest.after"
        cmp -s "$manifest" "$manifest.after" || {
            echo 'Source files changed during tests/build. Rerun release against a stable checkout.' >&2; exit 1;
        }
        scripts/package-release.sh "$APP" "$manifest"
        ;;
    verify) scripts/verify-release.sh "${2:?usage: ./build.sh verify path/to/Notch.dmg}" ;;
    run)    assemble; kill_app; sleep 0.3; open "${APP}"; echo "→ launched (no Dock icon — look at the notch)";;
    clean)  rm -rf .build build; echo "→ cleaned" ;;
    kill)   kill_app; echo "→ killed ${APP_NAME}" ;;
    logs)   tail -F "${HOME}/Library/Logs/Notch/notch.log" ;;   # notchLog writes here (NSLog doesn't reach unified log from a SwiftPM binary)
    *)      echo "usage: ./build.sh [build|run|test|release|verify DMG|clean|kill|logs]"; exit 1 ;;
esac
