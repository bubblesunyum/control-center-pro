#!/bin/bash
# Screenshots the panel, so a change to it can be reviewed by something other
# than the person who wrote it.
#
#   scripts/capture.sh [out.png]      # default: /tmp/ccp-panel.png
#
# Builds and launches the app with --show-panel, grabs the screen, crops to the
# panel's corner, and leaves the app running. Needs a GUI session with the
# display awake, and Screen Recording granted to whatever runs this.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Straight into /tmp, named ccp-*.png: that is where scripts/review.sh looks for
# the shots it hands the design reviewer, and it doesn't descend into
# subdirectories.
OUT="${1:-/tmp/ccp-panel.png}"
mkdir -p "$(dirname "$OUT")"

scripts/app.sh --show-panel > /dev/null

# The display asleep is the failure that looks like a bug in the app: the
# capture comes back pure black and nothing says why.
caffeinate -u -t 2 &
sleep 2

FULL="$(mktemp -t ccp-screen).png"
screencapture -x "$FULL"

# The panel anchors to the top-right, so crop that corner rather than shipping a
# reviewer a whole desktop to hunt through.
WIDTH=$(sips -g pixelWidth "$FULL" | awk '/pixelWidth/{print $2}')
CROP_W=1400
CROP_H=1400
sips --cropOffset 0 $((WIDTH - CROP_W)) --cropToHeightWidth $CROP_H $CROP_W "$FULL" --out "$OUT" > /dev/null
rm -f "$FULL"

echo "$OUT"
