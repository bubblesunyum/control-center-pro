# ARCHITECTURE.md

Expands on [CLAUDE.md](./CLAUDE.md)'s structure and data-flow philosophy. The
taste here came from psymail mini, the same author's other macOS menu-bar app,
where it was written for React; it is translated to SwiftUI and to this
project's fork constraints. It is durable taste, not a substitute for reading
the code.

## Composition first

Default to composing small views together. Reach for another pattern — a
generic rendering engine, a protocol-with-associated-type gymnastics layer, a
config-driven builder — only when composition is overwhelmingly more awkward,
and even then try a `ViewModifier` or a small observable before a structural
change.

## Atomic composition

Build from small primitives up, each layer composing the one below rather than
reaching past it:

```
GlassCard / LaneStack   →   WidgetChrome   →   SystemStatsWidget   →   ControlPanel
```

A primitive (`GlassCard`) shouldn't know about a domain (`AudioProcess`); a
panel shouldn't reimplement layout a primitive already solved. Noticing the same
view + logic shape twice is the primitive asking to be extracted.

## Capabilities, not features

When asked for a feature, look for the reusable capability underneath it. This
project's whole shape depends on it: a new tool should be *a `CCPWidget`
conformer and a registry entry*, nothing else. If adding a widget also requires
touching the shell, the lane layout, or the layout model, the capability
underneath it hasn't been built yet — build that instead of special-casing the
widget.

The same instinct applies to the fork boundary. An awkward upstream API is a
missing adapter, not a reason to reach into `Sources/Vorssaint/`.

## View shape

- One view, roughly one responsibility. Doing layout *and* sampling *and* three
  conditional branches is a view asking to be split.
- Don't over-split either. Private subviews in the same file as the view that
  uses them keep related code physically together. Promote one to its own file
  once something else imports it, or the file is genuinely hard to scan.
- Avoid deep nesting in `body` and in logic. Flatten with early returns,
  extracted subviews, or an extracted `ViewModifier` before adding another
  level. In SwiftUI deep nesting is also a performance question — it widens the
  scope that re-renders.
- Minimal wrapping containers. Don't add a `VStack` "just in case."

### Ergonomic APIs, graceful states built in

It's worth internal machinery to make a view pleasant at the call site: boolean
shorthand modifiers, a `Label`-style API that takes either a key or a full view,
and loading/empty/permission-denied states handled *inside* the component so
every caller gets them for free. That last one is not optional here — a widget
whose permission was denied has to render an inline "grant" state, and the right
place for that is one shared piece of widget chrome, not five copies.

Lean into this for shared foundation views, not for one-off surfaces, and stay
wary of ever-growing complexity: a slightly less elegant call site is worth it
when it makes the inside dramatically simpler.

### File organization

For a file of any real size: public API first, private helpers and subviews
next, then styles, types, and constants at the bottom. Section banners
(`// MARK: - Style`) once a file has enough sections to need signposting, not on
every short one.

## Observables for organization, not just reuse

Group related state and logic into an `@Observable` model even when only one
view will use it — the same way you'd break a long function into smaller ones. A
view's body should read like a short list of what this surface needs, not a wall
of intermixed `@State`.

Return shape signals intent: a tuple for a small positional pair, a named type
for a bag of several things. A non-obvious model or modifier is worth a one-line
usage example in a doc comment.

## Environment over threading state down

Default to `@Environment` (or the shared app model) for anything used by more
than one or two views down the tree. Thread values through initialisers only
when the drilling is shallow or the parent and child are intentionally coupled.

Ask what a view must be *given* — usually a callback or an id — versus what it
can *look up*. A widget should read the panel's edit-mode state from the
environment rather than having every lane pass it down.

## Views as configuration

Prefer expressing structure directly in view code over building a config array
that gets inflated into views later:

```swift
// prefer — the structure is visible at the call site
Lane {
  SystemStatsWidget()
  QuickTogglesWidget()
}
```

Config still earns its place where the content is genuinely data-shaped — the
persisted `[Lane]` layout and the `WidgetRegistry` are exactly that case, since
their content is user data, not authored structure. The smell to watch for is a
mapping layer growing more complex than the view code it replaced.

## The fork boundary, architecturally

Everything above stops at `Sources/Vorssaint/`. Upstream is a vendored library:
read it, wrap it, never reshape it. Each engine gets one CCPKit adapter exposing
an `@Observable` model and async APIs; CCPUI imports adapters and never an
upstream type. That single rule is what makes a monthly `merge upstream/main`
break one file instead of the app.
