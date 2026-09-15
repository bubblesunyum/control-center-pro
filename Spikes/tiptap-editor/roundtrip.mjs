// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

// Does markdown survive Tiptap unchanged? Parses each case into the editor and
// serializes it back. Reads the corpus; never writes it.
//   node roundtrip.mjs [dir-of-.md ...]
import { Window } from 'happy-dom'
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

const window = new Window()
for (const key of ['window', 'document', 'navigator', 'Node', 'HTMLElement', 'Element',
  'DOMParser', 'getComputedStyle', 'MutationObserver', 'Text', 'DocumentFragment', 'Range']) {
  if (!(key in globalThis)) globalThis[key] = key === 'window' ? window : window[key]
}
const { Editor } = await import('@tiptap/core')
const { noteExtensions } = await import('./src/extensions.js')

const editor = new Editor({ element: null, extensions: noteExtensions() })
const roundTrip = md => {
  editor.commands.setContent(md, { contentType: 'markdown' })
  return editor.getMarkdown()
}

// Craft's canonical forms (bd recall craft-normalises-markdown-on-write) and
// the shapes the pad has had to special-case.
const craft = {
  'paragraph': 'Just a line of text.',
  'bold': 'some **bold** words',
  'italic (craft uses *)': 'some *italic* words',
  'bold+italic': '***both*** here',
  'inline code': 'run `swift build` now',
  'link': 'see [Craft](https://craft.do) docs',
  'h1': '# Heading one',
  'h3': '### Heading three',
  'bullet': '- one item',
  'nested bullet (craft splits, child block)': '  - child item',
  'ordered': '1. first',
  'task open': '- [ ] buy milk',
  'task done': '- [x] bought milk',
  'quote': '> quoted line',
  'rule (craft ***)': '***',
  'code fence': '```swift\nlet x = 1\n```',
  'highlight (craft html)': 'a <highlight color="yellow">marked</highlight> word',
  'soft break in block': 'line one\nline two',
  'trailing space': 'ends with space ',
  'double space mid': 'two  spaces',
  'strike': '~~gone~~',
  'escaped star': 'price \\* 2',
  'underscore word': 'snake_case_name',
  'multi-block pad': '# Title\n\nFirst paragraph.\n\n- a\n- b\n\n- [ ] task\n\n> quote',
}

let same = 0, diff = 0
const report = (name, input, output) => {
  if (input === output) { same++; return }
  diff++
  console.log(`✗ ${name}\n    in : ${JSON.stringify(input)}\n    out: ${JSON.stringify(output)}`)
}
console.log('── craft block forms')
for (const [name, md] of Object.entries(craft)) report(name, md, roundTrip(md))

// A pad file is Craft blocks joined by the hard-break boundary (two trailing
// spaces + newline). Sync fidelity is per block: a block that comes back
// different is a block the push would rewrite in Craft.
// Inside a fence, trailing spaces are code, never a boundary — the same rule
// CraftBlockSplitter gets from the engine's AST.
const craftBlocks = md => {
  const blocks = []
  let current = [], inFence = false
  for (const line of md.split('\n')) {
    if (/^\s{0,3}(```|~~~)/.test(line)) inFence = !inFence
    const isBoundary = !inFence && /\S {2,}$/.test(line)
    current.push(isBoundary ? line.replace(/ +$/, '') : line)
    if (isBoundary) { blocks.push(current.join('\n')); current = [] }
  }
  blocks.push(current.join('\n'))
  return blocks.map(b => b.replace(/\n+$/, '')).filter(b => b.trim())
}
const shape = s => JSON.stringify(s.replace(/[A-Za-z0-9]/g, 'a').slice(0, 90))
const kinds = {}
let blocks = 0, blocksSame = 0, unstable = 0
for (const dir of process.argv.slice(2)) {
  console.log(`── blocks in ${dir}`)
  for (const file of readdirSync(dir).filter(f => f.endsWith('.md'))) {
    let fileSame = 0, fileBlocks = 0
    for (const block of craftBlocks(readFileSync(join(dir, file), 'utf8'))) {
      const once = roundTrip(block)
      if (roundTrip(once) !== once) unstable++
      fileBlocks++; blocks++
      if (once === block) { fileSame++; blocksSame++; continue }
      // Name the change by its first differing character run, masked.
      let i = 0
      while (i < block.length && block[i] === once[i]) i++
      const key = `${shape(block.slice(Math.max(0, i - 3), i + 6))} → ${shape(once.slice(Math.max(0, i - 3), i + 8))}`
      kinds[key] = (kinds[key] || 0) + 1
    }
    console.log(`  ${file}: ${fileSame}/${fileBlocks} blocks identical`)
  }
}
if (blocks) {
  console.log(`\n${blocksSame}/${blocks} real blocks identical; ${unstable} not a fixed point after one pass`)
  for (const [k, n] of Object.entries(kinds).sort((a, b) => b[1] - a[1]).slice(0, 25)) console.log(`  ${n}× ${k}`)
}
console.log(`\n${same} identical, ${diff} changed (block forms)`)
editor.destroy()
