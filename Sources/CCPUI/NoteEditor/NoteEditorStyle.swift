// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import SwiftUI

/// How the note editor's page looks on one kind of surface. The page takes
/// numbers, never design decisions: they are made here, from the design
/// system, and handed over as CSS variables.
struct NoteEditorStyle {
    /// Body size, and the base the heading ramp scales from.
    static let fontSize: CGFloat = 14

    /// The pad's vertical rhythm, both against the font's own natural line
    /// height: how far one wrapped line sits from the next inside a block,
    /// and how far one block sits from the next. The two are independent, so
    /// the text can breathe without the blocks running together.
    static let lineHeightRatio: CGFloat = 1.3
    static let blockSpacingRatio: CGFloat = 2.0

    /// A lane-width card gives a heading nowhere to be big: H1 at 1.6× reads
    /// as a heading without spending three lines of the card on one word.
    /// Documented in STYLE.md, where a bespoke type ramp belongs.
    static let headingScale: [CGFloat] = [1.6, 1.35, 1.15, 1.0, 0.95, 0.9]
    /// Air above a heading, in its own ems: roughly a blank line, Craft's
    /// proportion.
    static let headingTopSpacing: [CGFloat] = [0.8, 0.75, 0.7, 0.6, 0.5, 0.45]

    /// The line step and the block step at `size`, in whole points.
    static func rhythm(forFontSize size: CGFloat) -> (line: CGFloat, block: CGFloat) {
        let font = NSFont.systemFont(ofSize: size)
        let natural = font.ascender - font.descender + font.leading
        return ((natural * lineHeightRatio).rounded(), (natural * blockSpacingRatio).rounded())
    }

    let placeholder: String
    let insets: CGSize
    /// Empty room below the last line, as CSS: a caret typing at the bottom
    /// of a long note isn't pinned to the edge.
    let overscroll: String
    let accessibilityLabel: String

    /// The Notes well: roomy insets, so the text clears the well's edge by a
    /// visible margin on every side, and half a viewport of slack.
    static let notes = NoteEditorStyle(
        placeholder: "Write something…",
        insets: CGSize(width: Space.three + Space.one + Space.quarter, height: Space.three + Space.quarter),
        overscroll: "clamp(40px, 50vh, 450px)",
        accessibilityLabel: "Note text",
        appearance: nil
    )

    /// A sticky's paper: no inset — the card's grab border is already the
    /// margin — and no slack, which in a note this small would raise a
    /// scroller on text that visibly fits.
    static let sticky = NoteEditorStyle(
        placeholder: "Jot it down…",
        insets: .zero,
        overscroll: "0px",
        accessibilityLabel: "Sticky note text",
        appearance: NSAppearance(named: .aqua)
    )

    /// Paper stays light in either appearance, so its ink never lightens.
    let appearance: NSAppearance?

    var pageSettings: [String: Any] {
        let rhythm = Self.rhythm(forFontSize: Self.fontSize)
        var variables: [String: String] = [
            "font-size": "\(Self.fontSize)px",
            "line-height": "\(rhythm.line)px",
            "block-gap": "\(rhythm.block - rhythm.line)px",
            "inset-x": "\(insets.width)px",
            "inset-y": "\(insets.height)px",
            "overscroll": overscroll,
            "list-indent": "\(Space.three)px",
            "rule-gap": "\(Space.oneHalf)px",
            "code-fill": Self.css(Color.noteCodeFill),
        ]
        for (index, scale) in Self.headingScale.enumerated() {
            variables["h\(index + 1)"] = "\(scale)em"
            variables["h\(index + 1)-top"] = "\(Self.headingTopSpacing[index])em"
        }
        return ["variables": variables, "placeholder": placeholder]
    }

    private static func css(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "transparent" }
        let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
        return "rgba(\(channel(rgb.redComponent)), \(channel(rgb.greenComponent)), \(channel(rgb.blueComponent)), \(rgb.alphaComponent))"
    }
}
