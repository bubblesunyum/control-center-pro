#!/bin/bash
# Rebuilds the note editor page from the sibling bb-editor checkout and copies
# it into CCPUI's resources, stamped with the commit it came from. The bundle
# is committed, so `swift build` never needs node.
#
#   scripts/editor-bundle.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDITOR="$ROOT/../bb-editor"
OUT="$ROOT/Sources/CCPUI/Resources/NoteEditor"

[ -d "$EDITOR" ] || { echo "bb-editor is not checked out beside this repo: $EDITOR" >&2; exit 1; }
cd "$EDITOR"
[ -d node_modules ] || npm ci --silent
npx vitest run --silent >/dev/null || { echo "bb-editor tests fail — not bundling" >&2; exit 1; }
node scripts/build.mjs craft "$OUT/editor.html"
dirty=$(git status --porcelain | grep -q . && echo "-dirty" || true)
echo "bb-editor $(git rev-parse --short HEAD)$dirty" > "$OUT/VERSION"
cat "$OUT/VERSION"
