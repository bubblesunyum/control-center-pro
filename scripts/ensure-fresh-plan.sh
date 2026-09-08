#!/bin/bash
# Forces SwiftPM to notice added/removed files in the psymail-mini path
# dependency before the build runs. SwiftPM tracks known files by mtime but
# never re-scans a dependency's directories, so the first build after a commit
# that adds a source file fails with "cannot find X in scope" against an
# otherwise correct tree (psy-rfun) — and no retry, resolve, or manifest touch
# heals it. Deleting the cached plan makes SwiftPM re-scan while keeping every
# compiled object, so the next build pays one re-plan, not a full rebuild.
#
# Called by scripts/app.sh and scripts/verify.sh ahead of `swift build`.
# Silent on the fast path; the fingerprint lives in .build/ beside the plan it
# guards, so a `swift package reset` clears both together.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Mirrors the `.package(path:)` entry in Package.swift and the PsymailKit
# target's `path:` in psymail-mini's Package.swift. If either moves, move this.
SOURCES="$ROOT/../psymail-mini/PsymailMini"
FINGERPRINT="$ROOT/.build/psymail-sources.fingerprint"

# No sibling checkout (a lone CCP clone doesn't build — see PATCHES.md): leave
# the real error to `swift build` rather than failing here with a worse one.
[ -d "$SOURCES" ] || exit 0

current="$(find "$SOURCES" -name '*.swift' | sort | shasum -a 256)"
stored="$(cat "$FINGERPRINT" 2>/dev/null || true)"
if [ "$current" = "$stored" ]; then exit 0; fi

rm -f "$ROOT/.build/debug.yaml" "$ROOT/.build/release.yaml"
mkdir -p "$ROOT/.build"
printf '%s\n' "$current" > "$FINGERPRINT"
echo "psymail sources changed — dropped the cached SwiftPM plan so the build re-scans them"
