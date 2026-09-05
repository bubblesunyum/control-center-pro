<!-- tracks: Package.swift -->

@AGENTS.md

# CLAUDE.md

[AGENTS.md](./AGENTS.md) is the harness contract — how work is found, proved and
left behind, the same in every project running it. This file is the other half:
what is true only of control-center-pro. Neither repeats the other.

## Build

The gate is `scripts/verify.sh`, and AGENTS.md says how to run it. Underneath it
is SwiftPM — `swift build` / `swift test` — with a macOS deployment target of
**26.0**, which buys the macOS 26 SwiftUI surface (native `reorderable()`, Liquid
Glass). The CoreAudio process-tap API the audio mixer needs floors at 14.4, well
under it.
`--full` adds the app smoke launch.

There are two dependencies, and they are different in kind. **PsymailKit** is
the library lane of `../psymail-mini`, carried by a *path* dependency — the two
repos are developed as a pair in sibling checkouts, so a checkout of
control-center-pro alone will not resolve; see [PATCHES.md](./PATCHES.md).
**MarkdownEngine** (`bubblesunyum/swift-markdown-engine`, Apache-2.0, forked
from `nodes-app`) is the
Notes widget's live-styled Markdown editor, carried by a *URL* dependency pinned
exact to our own tag: unlike the Vorssaint engines we fork, it started as a
library we consumed unchanged — but CCP needs its block AST public and upstream
keeps its public surface small by policy, so the fork carries that seam and
merges from upstream are deliberate (ccp-aa5). Its resolution also pins HighlighterSwift and
SwiftMath, which only its opt-in code-block and LaTeX products link — CCP takes
the dependency-free core product and neither of those.

## Architecture Overview

Control Center Pro is a macOS menu-bar app: an `NSStatusItem` toggles a
non-activating `NSPanel` anchored top-right, blurred via `NSVisualEffectView`,
holding glass cards arranged in vertical lanes with an iOS-style edit mode.

It is a **fork of vorssaint-utils** (GPL-3.0-or-later) whose engines we vendor:

```
Sources/Vorssaint/…        upstream engines — vendored, never edited
Sources/CCPKit/            widget protocol, layout model, settings store, adapters
Sources/CCPUI/             glass shell, lanes, edit mode, design system
Sources/ControlCenterPro/  executable: app lifecycle, status item, wiring
```

The mail widget adds a second vendor alongside upstream, and it is a different
kind of vendoring: CCP does not read psymail's data and draw its own mail, it
**carries psymail's whole screen** — the tab bar and its bundles, the message
detail, search and compose are psymail's own views, running in a lane. That is
what `.screen` sizing exists for; a lane is as wide as the widest thing in it.

`../psymail-mini` exports `Psymail` (the mail graph, held across the panel
closing so a half-written reply survives it) and `PsymailScreen` (the view), and
`MailAdapter` is the one file in CCP that names them. Same rule as the engines —
the UI layer sees `MailAdapter` and never PsymailKit. The narrower
`PsymailInbox` data façade is still exported but no longer used here.

`BRIEF.md` is the full design and the build order. Read it before planning
anything structural.

## Philosophy

Durable taste, carried over from psymail mini and translated to SwiftUI. Long
form in [ARCHITECTURE.md](./ARCHITECTURE.md) and [STYLE.md](./STYLE.md).

- **Build capabilities, not isolated features.** Asked to add a tool? The
  capability underneath it is `CCPWidget` + a registry entry — if adding a
  widget also means touching the shell, the capability isn't built yet.
- **Prefer a flexible capability over a special case.** An override flag, a
  one-off branch, or config only one call-site reads is the moment to pause; a
  small composable primitive (a `ViewModifier`, a wrapper view, an observable)
  usually expresses it better and earns its keep at the next call-site. Don't
  overengineer ahead of need — but the moment a flow starts to *feel*
  complicated, treat that as the signal to zoom out and reshape rather than
  bolting on another special case.
- **Simplest structure the framework allows.** No abstraction layer, generic
  engine, or pattern where a plain view or observable would do.
- **Reach for the framework's built-in components first.** A stock `Menu`,
  `Section`, `ControlGroup`, `Label`, or `Slider` beats a hand-assembled
  lookalike — you inherit behaviour, accessibility, keyboard and pointer
  support, and platform feel for free, and delete code. Hand-roll only when the
  native piece genuinely can't do the job.
- **Small, single-purpose views; deep nesting is a smell.** More than roughly
  one responsibility, or `body` nesting more than a few levels, means extract —
  most naturally as a private subview in the same file. Minimal wrapping
  containers.
- **Keep files short and targeted.** Extracting inline comes first; once a file
  holds several substantial views or won't fit in your head, split it into files
  named for what they contain. A file that keeps growing is a capability waiting
  to be pulled out.
- **Let a view reach for shared state instead of threading it through.** Read
  from `@Environment` or the shared model and derive there — a parent shouldn't
  compute values only its child uses. Ask what a view must be *given* (a
  callback, an id) versus what it can *look up*.
- **Intrinsic data belongs on the model; where a thing is rendered belongs to
  the view.** A widget's icon and default size are attributes of the widget, so
  they live on its descriptor. Which lane it currently sits in is the layout's
  business. Resist a `placement`-style flag on the model that views must consult
  to lay themselves out.
- **Config is plain data; the type owns its behaviour.** Persisted layout stays
  names and ids (`[Lane]` of `WidgetID`); the registry turns one into a full
  value with its derived attributes. Constants belonging to a type live on the
  type, not in a config bag.
- **Use async/await.** Over completion handlers and Combine, unless there's a
  genuinely good reason.

## Naming

Lean toward Apple's precision, but note their verbosity sometimes goes
overboard: the fewest words that still fully and unambiguously describe the
thing. A good name reads like a small piece of documentation — `GlassCard`, not
`CardView2` or `BlurredGlassContainerCard`. Booleans read as booleans
(`isVisible`, `shouldRetry`), never `flag`/`data`-shaped.

Name for the concrete role or action, not a metaphor. Reach for an established
role suffix — `Controller`, `Store`, `Adapter`, `Representable` — over an
invented container noun (`Box`, `Holder`); an `NSViewRepresentable` wrapper for a
type is `<Type>Representable`.

Spell type names out in full; a widely-recognised abbreviation is fine for
members, parameters, and locals, shortening as scope narrows.

When naming a seam between components, describe the relationship it establishes,
not the one interaction it happens to enable today.

## Comments

Rare by default — clear names and structure shouldn't need narration. When one
shows up it explains a *why*: a workaround, a non-obvious constraint, a platform
gotcha. Never restate what the code already says.

## Animation

- Prefer animated transitions over UI that jumps between states.
- The goal is to show the eye where something came from and where it goes back
  to. Don't animate everything — only where it keeps the user oriented.
- Animate a few things purely for delight, where the interaction warrants it:
  fluid, springy, buttery. Edit mode's wiggle is one of these, and its per-item
  phase offset must be random so the widgets don't wiggle in lockstep.
- Turn animations into capabilities — modifiers and wrapper views with beautiful
  defaults and terse, overridable call-sites.
- Prefer a built-in transition (`.blurReplace`, `.push`, `.move`) over
  hand-animating scale/opacity/blur off a `@State` flag; it's terser, reads as
  intent, and the framework tunes the feel.
- The panel's open animation is a hard budget: under 100ms perceived.

## Accessibility

Icon-only controls — which this app is mostly made of — need an
`.accessibilityLabel`, and a value where they have state. Lean toward semantic
Dynamic Type styles over fixed point sizes so text honours the reader's setting;
reserve the fixed ramp in [STYLE.md](./STYLE.md) for the few places that need a
bespoke scale.

## Testing

Mock at the boundary — the engine's data source, the system API — not internals.
Build fixture factories (`fakeCPUSample()`) rather than inlining ad-hoc values.
Engines and adapters get unit tests against fake sources in `CCPKitTests`. What
a view *draws* is verified by screenshots through the review pass and by
`scripts/verify.sh --full`; the logic a shell type carries around its drawing —
event monitors installed and removed, lifecycle calls, layout mutation — is
`CCPUITests`, against a fake standing in for the AppKit API.

## Conventions & Patterns

- **Never edit upstream.** `Sources/Vorssaint/**`, `Sources/VMStatisticsCompat`,
  `Sources/FanControlHelper`, `Tools/`, `Resources/` are read-only. An awkward
  upstream API gets a CCPKit adapter, not a fix in place — that is what keeps
  `merge upstream/main` cheap. Genuinely needed upstream changes go up as a PR;
  local patches are a last resort and get recorded in [PATCHES.md](./PATCHES.md).
- **The engine layer is `VorssaintEngines`, not all of `Sources/Vorssaint`.**
  `Package.swift` excludes upstream's `App/` and `UI/` plus 38 files under
  `Core/`, `Services/`, and `Support/` that name a UI type by reference. If an
  engine you need is missing, check that list before assuming it isn't there —
  and read `PATCHES.md`, which explains what the list is and why it should
  shrink.
- **One adapter per engine.** CCP UI never touches an upstream type directly, so
  an upstream refactor breaks one file instead of the UI layer.
- Adapters expose `@Observable` models and async APIs; engine work runs off the
  main thread and publishes on it.
- Widgets `activate()` when the panel opens and `deactivate()` when it closes.
  Idle CPU with the panel shut is a feature, and it is ~0%.
- Permissions are gated per widget and degrade to an inline "grant" state — a
  missing permission never blocks the panel.
- **The user's data outranks the code that reads it.** A `Codable` type that is
  persisted must pin `CodingKeys` to the on-disk names, because renaming a
  property renames the stored key and every existing document stops decoding.
  And a failed decode is bytes you do not understand, never bytes you may
  replace: show an empty state, leave the stored value alone, and copy it aside
  before any write the user actually asked for. Both halves of that cost real
  notes on 2026-09-04 (ccp-uqn) — the rename was the bug, the write-on-failure
  was why it was unrecoverable.
- Spacing, radii, materials, and type come from the CCPUI design system, never
  from literals in a widget. See [STYLE.md](./STYLE.md).
- GPL-3.0-or-later: SPDX headers on every new file, upstream's headers left
  intact. Vorssaint's name, logo, and visual design are trademarked — none of
  their branding or distinctive UI, ever.
