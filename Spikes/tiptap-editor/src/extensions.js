// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

// One extension set for the panel editor and the round-trip harness, so what
// the harness proves is what the panel runs.
import StarterKit from '@tiptap/starter-kit'
import { Markdown } from '@tiptap/markdown'
import TaskList from '@tiptap/extension-task-list'
import TaskItem from '@tiptap/extension-task-item'
import { TableKit } from '@tiptap/extension-table'
import { CraftHighlight, CraftHorizontalRule, CraftTextEscaping } from './craftDialect.js'
import Placeholder from '@tiptap/extension-placeholder'

export function noteExtensions({ placeholder = '' } = {}) {
  return [
    StarterKit.configure({ link: { openOnClick: false }, horizontalRule: false }),
    CraftHorizontalRule,
    TaskList,
    TaskItem.configure({ nested: true }),
    CraftHighlight,
    TableKit,
    Placeholder.configure({ placeholder }),
    Markdown,
    CraftTextEscaping,
  ]
}
