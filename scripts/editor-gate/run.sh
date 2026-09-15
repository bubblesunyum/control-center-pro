#!/bin/bash
# The editor's key-driven gate (ccp-9vpv.1): real key events into a stand-in
# panel holding the bundled editor, so nobody's notes are touched. Prints the
# markdown after each step. Refuses on a locked screen, after less than five
# idle minutes, and before every batch unless its host is the front app —
# synthetic keys otherwise land in whatever the user has open
# (bd recall synthetic-keys-collide-with-the-users-typing).
#
#   scripts/editor-gate/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
H="$HERE/../../Sources/CCPUI/Resources/NoteEditor/editor.html"
WORK=/tmp/ccp-editor-gate
mkdir -p "$WORK" && cd "$WORK"
[ -x host ] && [ host -nt "$HERE/host.swift" ] || swiftc -O "$HERE/host.swift" -o host
[ -x drive ] && [ drive -nt "$HERE/drive.swift" ] || swiftc -O "$HERE/drive.swift" -o drive
if ioreg -n Root -d1 -a | grep -q CGSSessionScreenIsLocked; then echo "locked"; exit 3; fi
idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
[ "$idle" -ge 300 ] || { echo "user active ($idle s idle)"; exit 4; }
rm -f out.md log; ./host "$H" & HOST=$!
for _ in $(seq 50); do grep -q ready log 2>/dev/null && break; sleep 0.1; done
grep -q ready log || { echo "host not ready"; kill $HOST; exit 5; }
sleep 0.5
# Never type blind: every batch first proves the host is the front app, so
# no key can land in whatever the user left open.
front() { lsappinfo info -only name "$(lsappinfo front)" | grep -q '"host"' || { echo "host is not frontmost — stopping"; kill $HOST; exit 6; }; }
check() { sleep 0.4; printf '%-28s %s\n' "$1" "$(python3 -c 'import json,sys;print(json.dumps(open("out.md").read()))' 2>/dev/null)"; }
front; ./drive "text:hello" key:36 "text:second block" key:36:shift "text:soft line"; check "return / shift-return"
front; ./drive "text: two  spaces " ; check "spaces"
front; ./drive key:36 "text:- item" key:36 "text:next" key:36 key:36 "text:after"; check "list"
front; ./drive key:48 "text:x"; check "tab stays in editor"
front; ./drive key:36 'text:"it'"'"'s" -- ok...'; check "smart quotes/dashes"
front; ./drive key:0:cmd key:11:cmd; check "select all + bold"
front; ./drive key:6:cmd; check "undo"
front; ./drive key:6:cmdshift; check "redo"
kill $HOST
