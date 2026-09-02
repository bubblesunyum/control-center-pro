# Control Center Pro — Implementation Brief

## What we're building

A macOS menu bar app ("Control Center Pro" / CCP) that presents system utilities in a single, gorgeous, macOS-Control-Center-style panel: blurred/glassy backdrop, opening from the menu bar anchored at the **top-right**, expanding across the width of the screen as needed. Content is organized into **vertical lanes**; each lane stacks one or more widgets. Users rearrange widgets via an iOS-style **edit mode** (wiggling elements, drag-and-drop between/within lanes).

We are NOT embedding other apps' UI. All functionality is native, built on the feature engines of the GPL-3.0 project **vorssaint-utils** via a **fork-based in-tree strategy**: CCP is developed as a fork of vorssaint-utils that adds its own app target, leaving upstream's engine code untouched so we can merge new upstream features cheaply.

## Licensing constraints (non-negotiable)

- vorssaint-utils is **GPL-3.0-or-later**. Reusing its code means CCP must be GPL-3.0-or-later and open source. Put `LICENSE` (GPLv3) and SPDX headers in place from the first commit.
- Vorssaint's **name, logo, and visual design are trademarked** (see `vorssaint-src/TRADEMARKS.md`). Use none of its branding, icons, or distinctive UI. All UI is ours from scratch — which is the point anyway.

## Source material: what's in the clone

SwiftPM project (`swift-tools-version:5.9`), macOS 14+, Swift/SwiftUI/AppKit, no external dependencies except a small `VMStatisticsCompat` system-library shim. Layout:

- `Sources/Vorssaint/Services/` — the feature engines. **Mostly UI-free** (only 22 of 232 files import SwiftUI) — this is what we consume through adapters.
- `Sources/Vorssaint/UI/` (~41k lines) — their views. **Excluded from our build**; read only to learn how a service is consumed.
- `Sources/Vorssaint/Core/` — mostly localized strings (skip), plus a few useful bits: `Permissions.swift`, `GlobalShortcut.swift`, `Defaults.swift`, `FeatureCatalog.swift`.
- `Sources/FanControlHelper/` — privileged helper for fan control (skip for v1).

### Engine inventory (measured)

| Service dir | Size | v1? | Notes |
|---|---|---|---|
| `Metrics/` + `SystemMonitor/` | ~5.2k lines | **Yes** | CPU/GPU/mem/temps/net/disk/battery samplers. Cleanly separated samplers; the flagship widget. Needs `VMStatisticsCompat`. |
| `Audio/` | ~4.1k lines | **Yes** | Per-app volume mixer via CoreAudio process taps (`CATapDescription`, macOS 14.4+), output/input switching. Hardest engine to rewrite — port carefully, mostly intact. |
| `Clipboard/` | ~2.4k lines | **Yes** | History, ignored apps, auto-clear. |
| `Media/` | ~2.3k lines | **Yes** | Now-playing info/controls. |
| `Display/` | ~3.2k lines | **Yes** | Brightness (incl. external displays), appearance. |
| `KeepAwakeManager.swift` + support | small | **Yes** | Cheap win. |
| `Bluetooth/` | 151 lines | **Yes** | Tiny; sleep-toggle. |
| `Shelf/` | ~2.9k | Later | File shelf — good v2 lane. |
| `Snippets/` | ~1.3k | Later | |
| `WindowLayout/`, `Switcher/` | ~10.5k | Later | Window snapping/switcher; heavy AX permission surface. |
| `CommandBar/`, `QuickTools/`, `Recorder/`, `Cleaner/`, `Uninstall/`, `FanControl/` | ~30k | Later/No | Big; FanControl needs privileged helper. |

Also worth porting as shared infra: `HotkeyManager.swift`, `Permissions.swift`, `LaunchAtLogin.swift`, `Notifier.swift`, `BoundedProcessRunner.swift`.

## System design

### Fork strategy (the key structural decision)

1. Fork `vorssaintapp/vorssaint-utils` on GitHub; clone the fork; add the original as an `upstream` remote.
2. **Never edit upstream's files** (`Sources/Vorssaint/**`, `Sources/VMStatisticsCompat`, `Sources/FanControlHelper`, `Tools/`, `Resources/`). They are our vendored engine layer. All CCP code lives in new directories.
3. Periodically `git fetch upstream && git merge upstream/main`. Because our code is additive, conflicts should be limited to `Package.swift` and to upstream refactors of service APIs we call — which is the desired signal that an adapter needs updating. Always check with user before updating.
4. Write **adapters, not edits**: where an upstream service's API is awkward, wrap it in a CCP adapter type rather than reshaping their code. Resisting in-place cleanup is what keeps merges cheap.
5. If an upstream change is genuinely needed (e.g. exposing something `internal`), prefer submitting it as a PR upstream; patch locally only as a last resort, and track such patches in `PATCHES.md` so merge conflicts there are expected.
6. Longer-term: propose upstream a refactor splitting `Services/` into a `VorssaintKit` library product. If accepted, CCP can move from fork to a normal SwiftPM dependency.

### Package structure (SwiftPM, macOS 26+ target)

Extend the existing `Package.swift` (merge-conflict hotspot — keep our additions in a clearly-delimited block):

```
Sources/Vorssaint/…        — upstream engines (untouched, vendored)
Sources/CCPKit/            — widget protocol, layout model, settings store,
                             adapters wrapping upstream services
Sources/CCPUI/             — glass shell, lanes, edit mode, design system
Sources/ControlCenterPro/  — executable target: app lifecycle, status item, wiring
```

Note: upstream ships everything as a single `executableTarget` named `Vorssaint`, and executables can't be imported by other targets. So either (a) add a `.target(name: "VorssaintEngines", path: "Sources/Vorssaint", exclude: ["App", "UI", …])` library target over their sources in our `Package.swift` block (their `App/`/`UI/` stay excluded and unbuilt), or (b) compile their Services/Core/Support sources directly into `ControlCenterPro`. Prefer (a); it keeps the UI-free boundary compiler-enforced. Verify the exclude list still compiles after each upstream merge.

Rule: adapters/engines expose `@Observable` model objects + async APIs; CCP UI observes models and never reaches into upstream types directly — every upstream service is consumed through a `CCPKit` adapter, so upstream refactors break one adapter file, not the UI.

### The widget protocol — design this first

Everything hangs off it. Roughly:

```swift
protocol CCPWidget: Identifiable {
    static var descriptor: WidgetDescriptor { get }  // id, title, icon, default size, required permissions
    associatedtype Body: View
    @MainActor func makeView() -> Body               // the lane view
    // optional: settingsView, compact/expanded variants
    func activate()   // start sampling/observing when panel opens
    func deactivate() // stop when panel closes — engines must idle at ~0% CPU when hidden
}
```

A central `WidgetRegistry` lists available widgets; layout is `[Lane]` where `Lane = [WidgetID]`, persisted as Codable JSON in Application Support. New tools = new conformers; nothing else changes.

### Shell

- `NSStatusItem` → toggles a **non-activating `NSPanel`** (`.nonactivatingPanel`, level `.popUpMenu`, `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]`), anchored top-right of the screen the status item is on, width grows leftward with lane count up to full width.
- Real blur via `NSVisualEffectView` (material `.hudWindow` or `.popover`, `blendingMode: .behindWindow`) wrapped for SwiftUI; glassy cards on top (thin material, 1px white-alpha stroke, continuous corner radius ~16–20, subtle shadow). Match macOS Control Center's visual language without copying Vorssaint's.
- Dismiss on outside click (global `NSEvent` monitor) and Esc. Handle multiple displays (show on the display with the status item / mouse).

### Edit mode

- Long-press or "Edit" button enters edit mode: widgets wiggle (repeating small `rotationEffect`, **random per-item phase offset** so they don't sync), show remove badges, and become draggable.
- Prefer a custom drag gesture + `matchedGeometryEffect` for fluid reordering over `.draggable`/`.dropDestination` (the built-ins feel clunky for grid reordering). Drop targets: any position in any lane; empty trailing lane appears as a target to create a new lane.
- "+" opens a widget gallery (from `WidgetRegistry`) to add widgets.

### Performance & lifecycle rules

- Sampling only while panel is visible (or while a widget explicitly opts into background sampling, e.g. for menu-bar-icon stats). `activate()/deactivate()` enforce this.
- All engine work off the main thread; models publish on main.
- Panel open animation must be <100ms perceived; pre-warm the panel window at launch.

### Permissions

Gate features individually and degrade gracefully (widget shows an inline "grant permission" state, never blocks the whole panel). Needed by v1 set: microphone/audio-capture entitlement for process taps (audio mixer, macOS 14.4+ API — no permission dialogs for output mixing but test on device), Accessibility only when later window features land, none for metrics/clipboard/media/brightness (external-display brightness may use DDC via IOKit). Port `Permissions.swift` patterns.

## Build order (suggested)

1. Fork setup + `Package.swift` targets (see Fork strategy); confirm `VorssaintEngines` library target compiles with `App/`/`UI/` excluded.
2. Scaffold app: status item, glass panel, lanes with placeholder widgets, edit mode, layout persistence. **Get the shell feeling great before wiring engines.**
3. Adapter + widget for `Metrics`/`SystemMonitor` → System Stats: CPU/mem/temp graphs.
4. Adapters for `KeepAwake`, `Bluetooth`, `Display` → quick-toggles lane.
5. `Media` adapter → now-playing widget.
6. `Clipboard` adapter → clipboard history widget.
7. `Audio` adapter → per-app mixer widget (schedule the most time here; it's the deepest engine).
8. Then new tools / v2 engines (Shelf, Snippets, window management) — each is just a new adapter + widget.
9. Establish a routine: monthly (or per upstream release) `merge upstream/main`, fix adapters, skim their CHANGELOG for new engines worth surfacing as widgets.

Attribution: keep upstream's SPDX GPL headers intact; README states CCP is a fork of vorssaint-utils (© Vorssaint contributors, GPL-3.0-or-later) with an independent UI, and that Vorssaint trademarks are not used.

## Build & tooling

- SwiftPM like the source, but add an Xcode project or XcodeGen if entitlements/signing demand it (audio process taps require proper signing + `com.apple.security.device.audio-input`-adjacent entitlements; check `vorssaint-src/build.sh` for how they sign/bundle).
- macOS deployment target **26.0** (the macOS 26 SwiftUI surface; the
  process-tap API floors far below it at 14.4).
- Tests: engines get unit tests (samplers with fake data sources); UI is verified manually.

## Definition of done for v1

Panel opens from menu bar top-right with blur + glass lanes; ships with System Stats, Quick Toggles (keep-awake, Bluetooth, brightness, appearance), Now Playing, Clipboard History, and Per-App Audio Mixer widgets; edit mode with wiggle + drag-and-drop between lanes persists layout across launches; idle CPU ~0% with panel closed; GPLv3 licensed with attribution; a clean `merge upstream/main` has been performed at least once to prove the fork workflow holds.
