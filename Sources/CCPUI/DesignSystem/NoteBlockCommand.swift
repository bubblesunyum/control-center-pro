// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// A block kind the editor offers by name, and the group it is offered in.
///
/// `NoteBlock.Kind` says what a block *is*; this says how it is worded and
/// drawn in a menu, which is the editor's business rather than the note's.
/// A kind absent here is one nothing can reach yet — a divider needs a block
/// of its own inserted rather than a paragraph changed, so it waits.
enum NoteBlockCommand: String, CaseIterable, Identifiable {
    case paragraph, heading1, heading2, heading3
    case bulleted, numbered, todo
    case quote, code

    var id: String { rawValue }

    var kind: NoteBlock.Kind {
        switch self {
        case .paragraph: .paragraph
        case .heading1: .heading(level: 1)
        case .heading2: .heading(level: 2)
        case .heading3: .heading(level: 3)
        case .bulleted: .bulleted
        case .numbered: .numbered
        case .todo: .todo(isDone: false)
        case .quote: .quote
        case .code: .code(language: nil)
        }
    }

    var title: String {
        switch self {
        case .paragraph: "Body Text"
        case .heading1: "Heading"
        case .heading2: "Subheading"
        case .heading3: "Minor Heading"
        case .bulleted: "Bulleted List"
        case .numbered: "Numbered List"
        case .todo: "To-do"
        case .quote: "Quote"
        case .code: "Code"
        }
    }

    var symbol: String {
        switch self {
        case .paragraph: "text.alignleft"
        case .heading1: "textformat.size.larger"
        case .heading2: "textformat.size"
        case .heading3: "textformat.size.smaller"
        case .bulleted: "list.bullet"
        case .numbered: "list.number"
        case .todo: "checklist"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The command a block of this kind is currently sitting in, so the menu
    /// can show what the caret is in without the caller matching kinds itself.
    static func matching(_ kind: NoteBlock.Kind) -> NoteBlockCommand? {
        allCases.first { $0.kind.isSameKind(as: kind) }
    }

    static let textStyles: [NoteBlockCommand] = [.paragraph, .heading1, .heading2, .heading3]
    static let lists: [NoteBlockCommand] = [.bulleted, .numbered, .todo]
    static let blocks: [NoteBlockCommand] = [.quote, .code]
}
