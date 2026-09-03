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

# The mail widget's OAuth client credentials, if this checkout has them. They are
# merged in here rather than living in AppBundle/Info.plist because that file is
# tracked and these are a credential. Absent, the app still builds and runs — the
# widget just has nothing to sign in with. See AppBundle/Secrets.example.plist.
if [ -f AppBundle/Secrets.plist ]; then
  while IFS= read -r key; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" AppBundle/Secrets.plist)"
    # Set first, Add only if the key is new. A bare Add exits 1 on a key the
    # tracked Info.plist already carries, and under `set -e` that aborts the
    # assembly here — no PkgInfo, no signing — over a name collision.
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$BUNDLE/Contents/Info.plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$BUNDLE/Contents/Info.plist" > /dev/null
  done < <(/usr/libexec/PlistBuddy -c "Print" AppBundle/Secrets.plist | sed -n 's/^    \([^ ]*\) = .*/\1/p')
fi
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Prefer a stable identity so TCC grants (Documents, Accessibility,
# Screen Recording) survive rebuilds. Ad-hoc signatures change the cdhash
# on every build, which makes macOS treat each launch as a new app and
# re-prompt for every folder the WhatsApp organizer would touch (ccp-1kb).
# Order matches build.sh: Developer ID first, then the local self-signed
# "Vorssaint Utils Signing" created by Tools/setup-signing.sh, then ad-hoc.
developer_id_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true
}
LEGACY_IDENTITY="Vorssaint Utils Signing"
DEVID="$(developer_id_identity)"
if [[ -n "$DEVID" ]]; then
  echo "  signing with Developer ID: $DEVID" >&2
  codesign --force --sign "$DEVID" "$BUNDLE" > /dev/null 2>&1
elif security find-identity -p codesigning 2>/dev/null | grep -q "$LEGACY_IDENTITY"; then
  echo "  signing with $LEGACY_IDENTITY" >&2
  codesign --force --sign "$LEGACY_IDENTITY" "$BUNDLE" > /dev/null 2>&1
else
  echo "  signing ad-hoc (no stable identity — run Tools/setup-signing.sh to keep TCC grants across rebuilds)" >&2
  codesign --force --sign - "$BUNDLE" > /dev/null 2>&1
fi

if (( LAUNCH )); then
  restart_app "$BUNDLE" ${APP_ARGS+--args "${APP_ARGS[@]}"}
fi

echo "$BUNDLE"
