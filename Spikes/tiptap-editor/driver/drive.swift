// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

// Posts real keyboard events at the focused app, for driving the spike.
//   drive toggle | text:<chars> | key:<keycode>[:shift|cmd] | wait:<ms> ...
import CoreGraphics
import Foundation

let source = CGEventSource(stateID: .hidSystemState)

func press(_ code: CGKeyCode, flags: CGEventFlags = [], unicode: String? = nil) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
        event.flags = flags
        if let unicode {
            let utf16 = Array(unicode.utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        }
        event.post(tap: .cghidEventTap)
        usleep(12_000)
    }
}

for action in CommandLine.arguments.dropFirst() {
    let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
    switch parts[0] {
    case "toggle":
        press(50, flags: .maskCommand) // the panel's cmd-` shortcut
    case "text":
        for character in parts.count > 1 ? parts[1] : "" {
            if character == " " { press(49) } else { press(0, unicode: String(character)) }
        }
    case "key":
        let fields = parts[1].split(separator: ":")
        let flags: CGEventFlags = fields.count > 1 ? (fields[1] == "shift" ? .maskShift : .maskCommand) : []
        press(CGKeyCode(fields[0])!, flags: flags)
    case "wait":
        usleep(useconds_t(Int(parts[1])! * 1000))
    default:
        FileHandle.standardError.write("unknown action \(action)\n".data(using: .utf8)!)
    }
}
