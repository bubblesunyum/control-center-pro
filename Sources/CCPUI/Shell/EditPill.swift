// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit

/// The edit-mode pill, living inside the menu-bar item itself.
///
/// While editing, the status item stops being an icon and becomes Add on the
/// left with the checkmark on the right. The item's own highlight is the
/// containing pill; Add wears a smaller accent capsule inside it so the two
/// read as separate targets instead of one cramped pair. Template checkmark
/// with no forced color follows the bar — light, dark, and highlighted — the
/// way every other menu extra does; the white plus sits on the pill's own
/// saturated fill, which is the one place a forced color stays legible. The
/// checkmark keeps its Done behaviour; Add opens the gallery.
@MainActor
public final class EditPill: NSView {
    private var onDone: @MainActor () -> Void
    private var onAdd: @MainActor () -> Void
    private var onRightClick: @MainActor () -> Void

    private let doneButton = PillButton()
    private let addButton = PillButton()
    private let addWell = NSView()

    public init(
        onDone: @escaping @MainActor () -> Void,
        onAdd: @escaping @MainActor () -> Void,
        onRightClick: @escaping @MainActor () -> Void
    ) {
        self.onDone = onDone
        self.onAdd = onAdd
        self.onRightClick = onRightClick
        super.init(frame: .zero)

        addWell.wantsLayer = true
        addWell.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        addButton.image = Self.pillIcon(named: "plus", description: "Add widget")
        // White-on-accent, not white-on-unknown: the fill is the pill's own
        // saturated color in every appearance, so the glyph holds contrast
        // wherever the bar goes.
        addButton.contentTintColor = .white
        addButton.toolTip = "Add Widget"
        addButton.setAccessibilityLabel("Add widget")
        addButton.onRightClick = onRightClick
        prepare(addButton, action: #selector(didPressAdd))
        addWell.addSubview(addButton)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            addButton.leadingAnchor.constraint(equalTo: addWell.leadingAnchor, constant: Self.wellInsetX),
            addButton.trailingAnchor.constraint(equalTo: addWell.trailingAnchor, constant: -Self.wellInsetX),
            addButton.topAnchor.constraint(equalTo: addWell.topAnchor, constant: Self.wellInsetY),
            addButton.bottomAnchor.constraint(equalTo: addWell.bottomAnchor, constant: -Self.wellInsetY),
            addButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minTarget),
            addButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minTarget),
        ])

        doneButton.image = Self.pillIcon(named: "checkmark", description: "Done editing")
        doneButton.toolTip = "Done editing"
        doneButton.setAccessibilityLabel("Done editing")
        doneButton.onRightClick = onRightClick
        prepare(doneButton, action: #selector(didPressDone))
        NSLayoutConstraint.activate([
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minTarget),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minTarget),
        ])

        let stack = NSStackView(views: [addWell, doneButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Space.two
        stack.edgeInsets = NSEdgeInsets(
            top: 0, left: Space.half,
            bottom: 0, right: Space.half
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The well stays a capsule whatever height the menu bar gives it.
    override public func layout() {
        super.layout()
        addWell.layer?.cornerRadius = addWell.bounds.height / 2
    }

    /// Clicks on the item itself — the gaps and insets around the buttons —
    /// finish, the same as clicking the status button's own background today.
    /// The buttons eat their own presses first (they stay the hit views
    /// there), so this only ever answers for the dead strips between them.
    /// The Add well's own fill counts as Add: the accent ring around the plus
    /// reads as the target, and answering Done for it exits edit mode from
    /// an Add press (ccp-th8k).
    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if let hit = super.hitTest(point) {
            if hit is NSButton { return hit }
            if hit === addWell || hit.isDescendant(of: addWell) { return addButton }
            return self
        }
        return self
    }

    override public func mouseDown(with event: NSEvent) {
        onDone()
    }

    /// The pill covers the status button wholesale, so its menu would
    /// otherwise be unreachable while editing — every click lands in here,
    /// never on the button that used to pop it.
    override public func rightMouseDown(with event: NSEvent) {
        onRightClick()
    }

    /// Menu-bar icon scale, not the panel's: a status glyph reads beside the
    /// clock, not inside a card, so this is the bar's size on purpose.
    private static let symbolSize: CGFloat = 16
    /// Minimum tap target. Menu extras are small by nature; below this the
    /// gaps eat the presses and finishing answers for adding.
    private static let minTarget: CGFloat = 24
    /// The well's own padding: the capsule stands off the glyph on all sides.
    private static let wellInsetX: CGFloat = 7
    private static let wellInsetY: CGFloat = 5

    /// A template glyph with no forced tint, so the bar owns the color — the
    /// same contract every native menu extra keeps.
    private static func pillIcon(named name: String, description: String) -> NSImage? {
        let icon = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: symbolSize, weight: .medium))
        icon?.isTemplate = true
        return icon
    }

    private func prepare(_ button: NSButton, action: Selector) {
        button.isBordered = false
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func didPressDone() { onDone() }

    @objc private func didPressAdd() { onAdd() }
}

/// A pill button forwards right-clicks to the pill (which pops the status
/// menu): NSButton would otherwise swallow them the way the stack gaps used
/// to swallow background clicks.
private final class PillButton: NSButton {
    var onRightClick: (@MainActor () -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        guard let onRightClick else { super.rightMouseDown(with: event); return }
        onRightClick()
    }
}
