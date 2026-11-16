# Lifted from .claude/agents/reviewer-taste.md by harness migrate: the lines below occur in
# that file but not in the shared prompt. Prune what the shared
# prompt now covers; keep only this project's own checks.
description: Reviews a project diff against the project's documented taste — composition, module size, naming, comments, accessibility. Covers the app and the harness scripts. Reads a review packet and reports violations. Runs on Sonnet 5 at high effort; use for every change worth reviewing.
**Read `CLAUDE.md` first.** It is the standard. `ARCHITECTURE.md` and
`STYLE.md` expand it — read whichever the diff touches on: `ARCHITECTURE.md`
for composition, view shape, and state flow; `STYLE.md` for spacing, colour,
the glass vocabulary, and type. Then read the review packet you were given (a
path to a markdown file with the diff). Do not go exploring the whole repo; the
diff plus those documents is your scope. Read a changed file in full only when
the diff alone can't tell you whether something is a violation.
  framework already ships the thing. Stock pieces win unless they genuinely
  can't do the job — you inherit correct behavior and accessibility for free.
- **Accessibility.** Icon-only controls need a label. Semantic type styles over
  fixed sizes, so text honors the reader's settings.
This project is Swift 5.9+ / SwiftUI / AppKit on macOS 26+. Its specific rules:
- **Adapters, not edits.** Upstream (`Sources/Vorssaint/**`) is read-only. A
  diff that edits it, or CCP UI that imports an upstream type instead of a
  CCPKit adapter, is the most expensive violation available here — it is what
  makes the next upstream merge painful.
- **Concurrency model.** `@Observable` models on `@MainActor`, engine work in
  detached async work off it. `nonisolated` and `@unchecked Sendable` are claims
  that need a reason in a comment, not warning silencers.
- **Widget shape.** A new widget is a `CCPWidget` conformer plus a registry
  entry — nothing else should have to change. If a diff adds a widget and also
  touches the shell, lanes, or layout model, ask why.
- **Design system over one-offs.** Spacing, radii, materials, and type come from
  the CCPUI design system, not from literals in a widget's view. A hardcoded
  `16` or `.white.opacity(0.12)` in a widget is drift.
- **Views stay small.** A `body` that needs scrolling is a `body` that wants
  private subviews in the same file — before it earns a new file.
- **SPDX header** (`GPL-3.0-or-later`) on every new source file.
- **Accessibility.** Icon-only toggles — which this app is mostly made of —
  need `accessibilityLabel` and a value where they have state. Semantic type
  styles over fixed point sizes.
