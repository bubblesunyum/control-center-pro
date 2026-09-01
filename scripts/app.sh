#!/bin/bash
# Assembles Control Center Pro's .app bundle around the SwiftPM binary, and
# optionally launches it.
#
#   scripts/app.sh                        # build + assemble, print the bundle path
#   scripts/app.sh --launch               # ... and restart the running copy
#   scripts/app.sh --launch --show-panel  # ... with the panel already open
#   scripts/app.sh --edit-mode            # ... open, and in edit mode
#   scripts/app.sh --show-settings        # ... with the Settings window open
#   scripts/app.sh --show-shelf           # ... with the floating shelf open
#   scripts/app.sh --release              # optimized build
#
# build.sh at the repo root is upstream's and stays upstream's: it hand-rolls a
# swiftc build of the Vorssaint executable target, which this fork replaced with
# a library. Editing it would make every upstream merge a conflict for a build
# path we don't use. This is CCP's, it is twenty lines, and it goes through
# SwiftPM like the gate does.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION=debug
LAUNCH=0
APP_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --release)    CONFIGURATION=release ;;
    --launch)     LAUNCH=1 ;;
    --show-panel) LAUNCH=1; APP_ARGS+=(--show-panel) ;;
    --edit-mode)  LAUNCH=1; APP_ARGS+=(--show-panel --edit-mode) ;;
    --show-settings) LAUNCH=1; APP_ARGS+=(--show-settings) ;;
    --show-shelf) LAUNCH=1; APP_ARGS+=(--show-shelf) ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# `pkill` only sends the signal, and `open` on an .app that is still running
# reactivates the old process instead of launching the new binary — silently
# showing a stale build. Wait for it to actually go.
restart_app() {
  local bundle="$1"; shift
  pkill -f "/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true
  local waited=0
  while pgrep -f "/Contents/MacOS/$EXECUTABLE" > /dev/null 2>&1; do
    sleep 0.1
    waited=$((waited + 1))
    if [ "$waited" -gt 50 ]; then
      echo "the running app did not exit after 5s" >&2
      return 1
    fi
  done
  open "$bundle" "$@"
}

APP_NAME="Control Center Pro"
EXECUTABLE=ControlCenterPro
BUNDLE="build/$APP_NAME.app"

swift build -c "$CONFIGURATION" --product "$EXECUTABLE" > /tmp/ccp-app-build.log 2>&1 || {
  echo "build failed — see /tmp/ccp-app-build.log" >&2
  grep -E "error:" /tmp/ccp-app-build.log | sort -u | head -8 >&2
  exit 1
}
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/$EXECUTABLE"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY" "$BUNDLE/Contents/MacOS/$EXECUTABLE"
cp AppBundle/Info.plist "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Ad-hoc for now. The moment a widget needs a permission macOS ties to a binary
# hash — the audio mixer's process taps — this has to become the stable local
# identity instead, or every rebuild silently orphans the grant. That is
# ccp-4kq.1.
codesign --force --sign - "$BUNDLE" > /dev/null 2>&1

if (( LAUNCH )); then
  restart_app "$BUNDLE" ${APP_ARGS+--args "${APP_ARGS[@]}"}
fi

echo "$BUNDLE"
