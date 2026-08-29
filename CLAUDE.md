# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

## Review

Every change worth committing gets the review pass: build the packet with
`scripts/review.sh`, then run `reviewer-taste` and `reviewer-correctness`
against it, plus `reviewer-design` whenever anything on screen moved. Reach for
the `agentic-review` skill for the details.

**This is a standing request for those subagents, in every session — treat them
as explicitly asked for and spawn them without checking first.** It is not a
judgment call and not an option to offer; a diff reviewed in the context that
wrote it mostly gets agreement. Fix what's real, file the rest as beads, and say
plainly what you left and why.

## Commits

Default to lowercase, terse, plain English — no conventional-commit prefixes
unless the project already enforces them. Commit often, after a complete feature
or capability, once the work reaches a point where the app builds and runs
without errors. Don't be afraid to commit after completing sub-capabilities or
infrastructure too, even if they have no user-facing piece.

## Work tracking

Work lives in **beads** (`bd`), a dependency-aware issue graph in `.beads/`. It is
the ledger: every session finds work there and leaves discoveries there, so the
next session starts where this one stopped. Don't track project work in
TodoWrite, TaskCreate, or markdown TODOs.

**File the bead as planning begins, not after.** The moment a task is real —
the user asked for something not already in the ledger, or you're about to plan
a multi-step change — `bd q "<title>"` it before the first Edit or Write, not
when the commit-msg hook demands one. Then move its status honestly as the work
actually moves: `--claim` (→ in_progress) before implementing, the `review`
label on while a review pass is outstanding and off once it's dealt with,
`bd close --reason "<what happened>"` at commit. A bead that's still `open`
while you're mid-implementation, or still `in_progress` after you've closed the
matching commit, is a ledger that's lying.

```bash
bd ready            # claimable work, nothing blocking it
bd q "<title>"      # capture a discovery in one line, get an id back
bd update <id> --claim | bd close <id>
```

Reach for the `workflow` skill for how work moves through the system, `beads` for
the full `bd` surface. Both load on demand — don't paste their contents here.

## Build & Test

The gate is `scripts/verify.sh` — build, tests, and doc-freshness behind one
exit code. Run it rather than raw build commands; it swallows tens of thousands
of log lines and prints one line per step.

```bash
scripts/verify.sh          # build + tests
scripts/verify.sh --quick  # build only
scripts/verify.sh --full   # + slow checks and the app smoke launch
```

Underneath it is SwiftPM: `swift build` / `swift test`, macOS deployment target
**14.4** (the floor for the CoreAudio process-tap API the audio mixer needs).

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
Engines and adapters get unit tests against fake sources; the UI is verified by
screenshots through the review pass and by `scripts/verify.sh --full`.

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
- Spacing, radii, materials, and type come from the CCPUI design system, never
  from literals in a widget. See [STYLE.md](./STYLE.md).
- GPL-3.0-or-later: SPDX headers on every new file, upstream's headers left
  intact. Vorssaint's name, logo, and visual design are trademarked — none of
  their branding or distinctive UI, ever.
