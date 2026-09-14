// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

// The note editor as the panel's WKWebView runs it. Swift drives it through
// `window.ccpEditor`; it reports back on the `ccp` message handler.
import { Editor } from '@tiptap/core'
import { noteExtensions } from './extensions.js'

const post = (type, body = {}) => window.webkit?.messageHandlers?.ccp?.postMessage({ type, ...body })

// Markdown out on a short debounce: every keystroke serializing the whole
// document is wasted work when only the last one matters.
let pendingChange
const scheduleChange = () => {
  clearTimeout(pendingChange)
  pendingChange = setTimeout(() => post('change', { markdown: editor.getMarkdown() }), 150)
}

const editor = new Editor({
  element: document.querySelector('#editor'),
  extensions: noteExtensions({ placeholder: 'Write something…' }),
  onUpdate: scheduleChange,
})

window.ccpEditor = {
  /** Replaces the document without an update echo; returns the parse+render ms. */
  setMarkdown(markdown) {
    const start = performance.now()
    editor.commands.setContent(markdown, { contentType: 'markdown', emitUpdate: false })
    return performance.now() - start
  },
  focusEnd() {
    editor.commands.focus('end')
  },
  markdown() {
    return editor.getMarkdown()
  },
  /** Design tokens stay in Swift; the page only takes the numbers. */
  configure({ insetX, insetY, fontSize }) {
    const style = document.documentElement.style
    style.setProperty('--inset-x', `${insetX}px`)
    style.setProperty('--inset-y', `${insetY}px`)
    style.setProperty('--font-size', `${fontSize}px`)
  },
}

post('ready', { sinceNavigationMs: performance.now() })
