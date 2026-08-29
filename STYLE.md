# STYLE.md

Expands on [CLAUDE.md](./CLAUDE.md)'s styling pointer. Establish the shared
values at the start and keep them updated as the app grows — this is the single
biggest thing that keeps a UI consistent for near-zero ongoing effort.

For this project the shared style layer lives in `CCPUI` as the design system,
and it isn't optional: the panel's whole premise is that a dozen unrelated
widgets read as one surface. A widget should be buildable without a single
hardcoded spacing, radius, or colour literal.

## Spacing

One base unit — 8pt is a comfortable default — with every spacing value a
multiple of it, exposed as named steps rather than scattered raw numbers:

```swift
enum Space { static let x0_5 = 4.0, x1 = 8.0, x1_5 = 12.0, x2 = 16.0, x3 = 24.0 }
```

Named steps first, a raw number close to never. This is also what the design
reviewer is measuring against: a surface using 9, 12, 14, 18 and 20 as gaps is
five words for one idea, and each difference is a claim the eye has to test and
discard. Collapse to the same value or commit to an obviously different one —
splitting the difference is the answer that's always wrong.

## Color

Two tiers:

1. A raw palette named by hue and lightness (`gray300`, `blue500`) — the actual
   values.
2. Semantic aliases over it (`accent`, `cardStroke`, `labelMuted`) — what views
   actually reach for.

Semantic names first, palette names second, a raw hex close to never. A
genuinely new colour goes in the palette, then earns a semantic name once a
second view needs it.

For this app most colours should be *system* colours — `.secondaryLabel`,
`Color.accentColor`, the materials — because the panel floats over an unknown
wallpaper in either appearance and system colours already solve that. Fixed
values are for the glass vocabulary itself.

## The glass vocabulary

The panel's look, in one place, because every widget inherits it:

- Real blur behind the window (`NSVisualEffectView`, `.hudWindow` or `.popover`,
  `blendingMode: .behindWindow`) — never a material fill pretending to be blur.
- Cards: thin material, a 1pt white-alpha hairline stroke, continuous corner
  radius around 16–20, a soft shadow.
- SF Symbols throughout; system accent for active toggles, secondary label for
  everything at rest.
- Lanes with consistent gutters; the card radius and the panel radius are a
  nested pair, so they either match deliberately or differ obviously.

It should read as macOS Control Center's language. It must not read as
Vorssaint's — their visual design is trademarked, and none of it comes across
the fork boundary.

## Rows own their edges

Where a card holds a list of rows, the padding belongs to the rows, not the
card. A row draws its own hover fill, selection, and divider, and all of those
have to reach the card's full inner width. Pad the container instead and every
one of them stops short — a highlight in a matte, a second rectangle nobody
chose to draw. Three things go with it: the card clips, the rows carry the
horizontal inset the card used to, and the row's whole width is the hit target.

## Type

Semantic Dynamic Type styles (`.headline`, `.body`, `.caption`) over fixed point
sizes, so text honours the reader's setting. Reserve a fixed ramp for the few
places that genuinely need a bespoke scale — a numeric readout in a stats
graph, say — and put it here rather than inline.

## One pattern per container

Within a single card, bar, or section, everything pressable looks pressable the
same way: same height, padding, type, icon treatment, alignment. Two actions in
one card, one a small muted label and the other a full-width row with a leading
icon, is a defect even when each looks fine alone — the geometry says they do
different kinds of thing when they don't.
