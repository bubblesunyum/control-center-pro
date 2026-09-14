// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

// Craft's markdown, spoken back the way Craft writes it (bd recall
// craft-normalises-markdown-on-write). Each rule is the answer to one diff the
// round-trip harness found against real pads.
import { Extension } from '@tiptap/core'
import HorizontalRule from '@tiptap/extension-horizontal-rule'
import Highlight from '@tiptap/extension-highlight'

/** Craft writes a rule as `***`; Tiptap's default is `---`. */
export const CraftHorizontalRule = HorizontalRule.extend({
  renderMarkdown: () => '***',
})

/** Craft stores highlight as `<highlight color="…">…</highlight>`, not `==…==`. */
export const CraftHighlight = Highlight.extend({
  addAttributes() {
    return { color: { default: 'yellow' } }
  },
  markdownTokenizer: {
    name: 'highlight',
    level: 'inline',
    start: src => src.indexOf('<highlight'),
    tokenize(src, _tokens, lexer) {
      const match = /^<highlight(?:\s+color="([^"]*)")?>([\s\S]*?)<\/highlight>/.exec(src)
      if (!match) return undefined
      return { type: 'highlight', raw: match[0], color: match[1] || 'yellow',
        tokens: lexer.inlineTokens(match[2]) }
    },
  },
  parseMarkdown: (token, helpers) =>
    helpers.applyMark('highlight', helpers.parseInline(token.tokens || []), { color: token.color }),
  renderMarkdown: (node, helpers) =>
    `<highlight color="${node.attrs?.color || 'yellow'}">${helpers.renderChildren(node)}</highlight>`,
})

/**
 * Escape only what would otherwise parse as syntax. Upstream backslashes every
 * `_ * [ ~` and entity-encodes every `& < >`, so `snake_case` comes back as
 * `snake\_case` — a changed block to the sync, and noise in the vault.
 */
export const CraftTextEscaping = Extension.create({
  name: 'craftTextEscaping',
  // Below Markdown's default 100, so its manager exists by the time this runs.
  priority: 50,
  onBeforeCreate() {
    const manager = this.editor.markdown
    const upstream = manager.encodeTextForMarkdown.bind(manager)
    manager.encodeTextForMarkdown = (text, node, parentNode) => {
      const plain = upstream(text, node, parentNode)
      if (plain === text) return text // code context: upstream left it alone
      const minimal = text.replace(/<(?=[A-Za-z/!?])/g, '&lt;').replace(/&(?=#?\w+;)/g, '&amp;')
      const tokens = manager.markedInstance.Lexer.lexInline(minimal, manager.markedInstance.defaults)
      const isPlainText = tokens.every(t => t.type === 'text' && !/\\/.test(t.raw))
        && tokens.map(t => t.raw).join('') === minimal
      return isPlainText ? minimal : plain
    }
  },
})
