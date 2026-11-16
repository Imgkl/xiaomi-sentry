#!/bin/bash
# Builds "Xiaomi Sentry.app" into ./build.
# Usage: scripts/build-app.sh [--open | --install]
#   --open     start the app from ./build
#   --install  move it to /Applications (no second copy stays in ./build) and start it
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product XiaomiSentry
BIN="$(swift build -c release --show-bin-path)/XiaomiSentry"

APP="build/Xiaomi Sentry.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/XiaomiSentry"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Signing identity: the one named in .signing-identity (gitignored; a name or SHA-1 from
# `security find-identity -v -p codesigning`), else the first Apple Development identity,
# else ad hoc. Local Network privacy tracks the app by its signature, so keep it stable.
IDENTITY="$(cat .signing-identity 2>/dev/null || security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad hoc identity})"

case "${1:-}" in
  --open)
    pkill -x XiaomiSentry 2>/dev/null || true
    open "$APP"
    ;;
  --install)
    pkill -x XiaomiSentry 2>/dev/null || true
    rm -rf "/Applications/Xiaomi Sentry.app"
    mv "$APP" /Applications/
    open "/Applications/Xiaomi Sentry.app"
    echo "Installed /Applications/Xiaomi Sentry.app"
    ;;
esac
