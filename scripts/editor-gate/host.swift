// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

// The editor gate's stand-in for the panel (ccp-9vpv.1): a non-activating panel holding the real editor
// bundle, with the app's Edit menu, so driven keys prove the page without
// touching anyone's notes. Every change lands in ./out.md; timings in ./log.
import AppKit
import WebKit

let html = URL(fileURLWithPath: CommandLine.arguments[1])
let outURL = URL(fileURLWithPath: "out.md")
let logURL = URL(fileURLWithPath: "log")
func log(_ s: String) { if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!) } else { try? (s + "\n").write(to: logURL, atomically: true, encoding: .utf8) } }

final class WebView: WKWebView { override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } }
final class Panel: NSPanel { override var canBecomeKey: Bool { true } }

final class Host: NSObject, WKScriptMessageHandler {
    let panel = Panel(contentRect: NSRect(x: 200, y: 200, width: 420, height: 360), styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
    var web: WebView!
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        let body = m.body as? [String: Any] ?? [:]
        switch body["type"] as? String {
        case "ready":
            web.evaluateJavaScript("bbEditor.configure({variables: {'inset-x': '16px', 'inset-y': '16px'}, placeholder: 'Write something…'}); bbEditor.open('gate', '')") { _, e in
                if let e { log("js \(e)") }
                NSApp.activate(ignoringOtherApps: true)
                self.panel.makeKeyAndOrderFront(nil)
                self.panel.makeFirstResponder(self.web)
                self.web.evaluateJavaScript("bbEditor.focus('gate', 'end')")
                log("ready")
            }
        case "change":
            try? (body["markdown"] as? String ?? "").write(to: outURL, atomically: true, encoding: .utf8)
        default: break
        }
    }
    func start() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "bbEditor")
        web = WebView(frame: panel.contentView!.bounds, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        panel.contentView!.addSubview(web)
        panel.isFloatingPanel = true
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let main = NSMenu()
let appItem = NSMenuItem(); appItem.submenu = NSMenu(); main.addItem(appItem)
let edit = NSMenu(title: "Edit")
edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)
app.mainMenu = main
let host = Host()
host.start()
app.run()
