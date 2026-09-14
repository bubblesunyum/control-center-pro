#!/bin/bash
# Drives the running app's spike editor with real key events and prints what
# landed. Needs an unlocked GUI session, spikeTiptapNotes and
# spikeTiptapScratch on, and the panel closed to start.
set -euo pipefail
DRIVE=/tmp/ccp-drive
[ -x "$DRIVE" ] || swiftc -O -o "$DRIVE" "$(dirname "$0")/driver/drive.swift"
if ioreg -n Root -d1 -a | grep -q CGSSessionScreenIsLocked; then echo "screen locked" >&2; exit 3; fi
caffeinate -u -t 2
: > /tmp/ccp-tiptap-spike.log

# The typing that breaks the native pad: a space at the end of a block with a
# block below, double spaces, return vs shift-return, lists, tasks, headings.
"$DRIVE" toggle wait:700 \
  "text:hello" key:36 "text:second block" key:36:shift "text:soft line" key:36 \
  "text:- item one" key:36 "text:item two" key:36 key:36 \
  "text:[ ] task" key:36 "text:## heading" key:36 "text:**bold** and *it* end" \
  key:126:cmd key:124:cmd "text: world  two  spaces " key:125 "text: more" wait:600
screencapture -x /tmp/ccp-spike-typed.png
echo "── typed document"; cat /tmp/ccp-tiptap-spike.md; echo

# Warm opens: close and reopen, each open logs its next-frame latency.
for _ in 1 2 3 4 5 6; do "$DRIVE" key:53 wait:500 toggle wait:500; done
echo "── timings"; grep -E "panel open|cold|setMarkdown" /tmp/ccp-tiptap-spike.log
ps -axo rss,comm | awk '/WebContent|MacOS\/ControlCenterPro/ {printf "%6.0f MB %s\n", $1/1024, $2}'
