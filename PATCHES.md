# PATCHES.md

Local modifications to upstream's tree (`Sources/Vorssaint/**`,
`Sources/VMStatisticsCompat`, `Sources/FanControlHelper`, `Tools/`,
`Resources/`, `Package.swift`).

The rule from [BRIEF.md](./BRIEF.md): prefer a CCP adapter over a patch, and
prefer a PR upstream over a local patch. Anything here is a last resort, and it
is here so that a conflict in these files during `merge upstream/main` is
expected rather than alarming. Every entry says what, why, and what would let us
delete it.

---

## `Package.swift` — the whole CCP block

**What.** Deployment target raised 14.0 → 14.4; upstream's `Vorssaint`
executableTarget replaced by a `VorssaintEngines` library target over the same
path; `CCPKit`, `CCPUI`, `ControlCenterPro`, and `CCPKitTests` added.

**Why.** SwiftPM won't let two targets share source files, and an executable
target can't be imported — so upstream's engines are unreachable from our code
until they are declared as a library. 14.4 is the floor for `CATapDescription`,
which the per-app audio mixer is built on.

**Deleting it.** Step 6 of the BRIEF: propose upstream split `Services/` into a
`VorssaintKit` library product. If they take it, CCP moves from a fork to an
ordinary SwiftPM dependency and this block mostly evaporates.

**On merge.** Expect a conflict here every time either side touches the
manifest. Keep our fenced blocks; re-check `exclude` if upstream adds a
directory under `Sources/Vorssaint`.

---

## `Sources/Vorssaint/Core/Permissions.swift` — UI overlay behind a hook

**What.** Four lines. `requestAccessibility()` and `requestScreenRecording()`
called `PermissionGuideOverlay.shared.show(for:)` directly; they now hop to the
main actor and call an optional `Permissions.showGuide` closure. Added
`Permissions.GuideKind` and the `@MainActor showGuide` static, both fenced in
`CCP PATCH` comments.

The hook is main-actor isolated rather than `nonisolated(unsafe)`: it ends in a
view update, `Permissions` is a plain `ObservableObject` with no isolation of
its own, and this same file already hops to `DispatchQueue.global` in three
places — so a background caller is realistic. Isolating the property makes the
compiler enforce the hop at every call site rather than trusting a comment.

**Why.** `PermissionGuideOverlay` lives in `UI/`, which this fork does not
build. Every attempt to exclude `Permissions.swift` instead failed badly: it is
foundational, and dropping it produced **1336** compile errors across the engine
layer. Four patched lines against 1336 errors is not a close call.

It also happens to be the better design for us — a permission engine shouldn't
know how a permission is presented, and CCP renders an inline "grant" state in
the widget rather than a floating card.

**Deleting it.** Send it upstream. The change is small, strictly more flexible
than what's there, and costs them nothing: they set `showGuide` to their overlay
at startup. If accepted, this entry goes away entirely.

**On merge.** Conflicts only if upstream edits those two methods. Reapply the
hook rather than taking their overlay call.

---

## Not a patch: `build.sh` is upstream's, and CCP doesn't use it

`build.sh` at the repo root hand-rolls a `swiftc` build of upstream's
`Vorssaint` executable target, assembles their bundle, and signs it with their
identity. That target no longer exists in this fork — the `Package.swift` patch
above replaced it with the `VorssaintEngines` library — so the script cannot
build anything here.

It is left exactly as upstream wrote it anyway. Editing 631 lines of someone
else's build to produce our bundle would make every upstream merge a conflict
over a code path we don't run. CCP's own bundle is `scripts/app.sh`: twenty
lines, SwiftPM underneath, `AppBundle/Info.plist` for the identity, the same
compiler the gate uses.

Closed as ccp-v64, which had asked for the identity rename in place.

---

## Not a patch: the `exclude` list

`Package.swift` excludes 38 files under `Core/`, `Services/`, and `Support/`.
Those files are unmodified — they are simply not compiled, because they name a
type that lives in `UI/`.

This is worth stating plainly because BRIEF.md predicted otherwise: it measured
upstream's `Services/` as "mostly UI-free" by counting SwiftUI imports (22 of
232). Coupling by *reference* is wider than coupling by import — 24 files name a
UI type directly, and another 14 fall out behind them.

Almost all of it is the BRIEF's own "Later/No" column: CommandBar, QuickTools,
Recorder, Shelf, Snippets, Switcher, RadialMenu, DockPreview, Cleaner. Three
v1-relevant files are casualties and have beads of their own:

| File | Needs | Bead |
|---|---|---|
| `Services/Clipboard/ClipboardHistoryService.swift` | `ClipboardQuickPanelView` | ccp-8ld.5 |
| `Services/Clipboard/ClipboardAutoClearService.swift` | the above | ccp-8ld.5 |
| `Services/SystemMonitor/ProcessUsageService.swift` | `BreakdownKind` | ccp-8ld.2 |

Every other v1 engine came through whole: Metrics 16/16, Audio 10/10, Media 3/3,
Display 5/5, Bluetooth 2/2, KeepAwake, and 3 of 4 SystemMonitor files.

**The list should shrink.** It is the honest measure of the fork boundary, and
each file that leaves it is either an upstream PR that landed or a leak we
learned to route around.
