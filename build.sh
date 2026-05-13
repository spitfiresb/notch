#!/usr/bin/env bash
# Build / run helper for the Notch app. See BUILD.md.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Notch"
CONFIG="${CONFIG:-debug}"          # set CONFIG=release for an optimized build
BUILD_DIR=".build/${CONFIG}"
APP="build/${APP_NAME}.app"

kill_app() { pkill -x "${APP_NAME}" >/dev/null 2>&1 || true; }

assemble() {
    swift build -c "${CONFIG}"
    rm -rf "${APP}"
    mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
    cp "${BUILD_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
    cp Resources/Info.plist "${APP}/Contents/Info.plist"
    # ad-hoc sign so TCC (Accessibility / Automation) has something to attach grants to
    codesign --force --deep --sign - "${APP}" >/dev/null 2>&1 || true
    echo "→ built ${APP}"
}

case "${1:-build}" in
    build)  assemble ;;
    run)    assemble; kill_app; sleep 0.3; open "${APP}"; echo "→ launched (no Dock icon — look at the notch)";;
    clean)  rm -rf .build build; echo "→ cleaned" ;;
    kill)   kill_app; echo "→ killed ${APP_NAME}" ;;
    logs)   log stream --predicate "process == \"${APP_NAME}\"" --level debug ;;
    *)      echo "usage: ./build.sh [build|run|clean|kill|logs]   (CONFIG=release for optimized)"; exit 1 ;;
esac
