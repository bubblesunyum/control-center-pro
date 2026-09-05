// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit

/// The application's main menu, which an `.accessory` app never shows and
/// cannot work without.
///
/// ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z are not behaviour `NSTextView` implements — they are
/// key equivalents that `NSMenu` dispatches down the responder chain before
/// anything else sees the event. With no main menu installed nothing performs
/// that dispatch, so the keystrokes fall on the floor even in a key panel with
/// a first responder that would happily have handled them.
///
/// Installing the standard items fixes every editable surface at once, and
/// brings Services, dictation and the character picker with it.
public enum ApplicationMenu {
    /// The Services submenu's title, which is also how `install` finds it
    /// again to hand to `NSApplication`.
    static let servicesTitle = "Services"

    /// Give `application` a main menu. Safe to call once, at launch.
    @MainActor
    public static func install(in application: NSApplication) {
        let main = standard(applicationName: ProcessInfo.processInfo.processName)
        application.mainMenu = main
        application.servicesMenu = main.items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .first(where: { $0.title == servicesTitle })?
            .submenu
    }

    /// Built separately from `install` so a test can inspect it without an
    /// `NSApplication`.
    @MainActor
    public static func standard(applicationName: String) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu: applicationSubmenu(applicationName: applicationName))
        main.addItem(submenu: editSubmenu())
        return main
    }

    @MainActor
    private static func applicationSubmenu(applicationName: String) -> NSMenu {
        let menu = NSMenu(title: applicationName)
        menu.addItem(withTitle: "About \(applicationName)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(submenu: NSMenu(title: servicesTitle))
        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide \(applicationName)",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(applicationName)",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        return menu
    }

    @MainActor
    private static func editSubmenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pastePlain = menu.addItem(withTitle: "Paste and Match Style",
                                      action: #selector(NSTextView.pasteAsPlainText(_:)),
                                      keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }
}

private extension NSMenu {
    /// `NSMenu` only accepts a submenu through an item, and the item's own
    /// title is what the menu bar draws — so the two travel together.
    @discardableResult
    func addItem(submenu: NSMenu, title: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
        return item
    }
}
