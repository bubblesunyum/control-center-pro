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

**What.** Deployment target raised 14.0 → 26.0; upstream's `Vorssaint`
executableTarget replaced by a `VorssaintEngines` library target over the same
path; `CCPKit`, `CCPUI`, `ControlCenterPro`, and `CCPKitTests` added.

**Why.** SwiftPM won't let two targets share source files, and an executable
target can't be imported — so upstream's engines are unreachable from our code
until they are declared as a library. The target was 14.4 for a while — the
floor for `CATapDescription`, which the per-app audio mixer is built on — and
went to 26.0 so the app can use the macOS 26 SwiftUI surface.

The raise costs 7 deprecation warnings, all inside vendored upstream we never
edit: `Services/Recorder/RecorderComposer.swift` (`AVMutableVideoComposition`
and friends, deprecated in 26.0) and `Services/Homebrew/HomebrewManager.swift`
(`init(contentsOfFile:)`, deprecated in 15). No errors. They are expected noise;
if upstream ever modernizes those call sites the warnings go on their own.

**Deleting it.** Step 6 of the BRIEF: propose upstream split `Services/` into a
`VorssaintKit` library product. If they take it, CCP moves from a fork to an
ordinary SwiftPM dependency and this block mostly evaporates.

**On merge.** Expect a conflict here every time either side touches the
manifest. Keep our fenced blocks; re-check `exclude` if upstream adds a
directory under `Sources/Vorssaint`.

---

## `Sources/VorssaintBridge/` — the visibility shims

**What.** The `VorssaintEngines` target's path is `Sources` rather than
`Sources/Vorssaint`, and it compiles two directories:
`sources: ["Vorssaint", "VorssaintBridge"]`. The second is ours. Every entry in
`exclude` carries a `Vorssaint/` prefix as a result.

**Why.** Every upstream type is `internal`, so *nothing* in the engine layer is
visible across a module boundary — `import VorssaintEngines; Permissions.shared`
fails to compile from CCPKit. Files in `VorssaintBridge/` are module-mates of
upstream, so they can see internal types and re-export what CCP needs as
`public`. The alternative was `-enable-testing` plus `@testable import`, which
puts a test-only facility on the production path and gives up cross-module
optimization. This costs no upstream edits at all.

**The rule.** A shim may restate a type; it may not decide anything about one.
No stored state, no policy, no branch that could have gone the other way. A
`switch` mapping an upstream enum onto a public one is a restatement — it has
one correct form. Anything with a judgement call in it is an adapter, and
adapters live in `Sources/CCPKit/Adapters`. See `Sources/VorssaintBridge/README.md`.

**Deleting it.** Same as the manifest block above: if upstream ships a
`VorssaintKit` library product with public API, the shims evaporate with it.

**On merge.** `VorssaintBridge/` is ours and never conflicts. The `exclude`
prefixes do — if upstream adds a file that must be excluded, remember the
`Vorssaint/` prefix or the manifest will fail with "unexpected input file".

---

## `Sources/Vorssaint/Services/Clipboard/ClipboardHistoryService.swift` — quick panel behind a hook

**What.** `ensurePanel()` constructed `NSHostingController(rootView: ClipboardQuickPanelView())` directly; it now calls an optional `makeQuickPanelContent` factory. Added `static var makeQuickPanelContent: (() -> NSViewController)?` fenced in `CCP PATCH`. The original `host.sizingOptions = []` is now set inside the factory when the type is known.

**Why.** `ClipboardQuickPanelView` lives in `UI/`, which this fork does not build. The hook mirrors `Permissions.showGuide`: upstream sets the factory to its view at launch, CCP leaves it nil and shows history in its own widget. Without the hook the file cannot compile in `VorssaintEngines`.

**Deleting it.** Send the hook upstream — small, strictly more flexible, costs them nothing. If accepted, this entry goes away.

**On merge.** Conflicts only if upstream edits `ensurePanel()`. Reapply the hook.

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

`Package.swift` excludes 36 files under `Core/`, `Services/`, and `Support/`.
Those files are unmodified — they are simply not compiled, because they name a
type that lives in `UI/`.

This is worth stating plainly because BRIEF.md predicted otherwise: it measured
upstream's `Services/` as "mostly UI-free" by counting SwiftUI imports (22 of
232). Coupling by *reference* is wider than coupling by import — 24 files name a
UI type directly, and another 14 fall out behind them.

Almost all of it is the BRIEF's own "Later/No" column: CommandBar, QuickTools,
Recorder, Shelf, Snippets, Switcher, RadialMenu, DockPreview, Cleaner. One
v1-relevant file is still a casualty and has its own bead; the clipboard pair
was patched in `ccp-8ld.5` and now builds:

| File | Needs | Bead |
|---|---|---|
| `Services/SystemMonitor/ProcessUsageService.swift` | `BreakdownKind` | ccp-8ld.2 |

Every other v1 engine came through whole: Metrics 16/16, Audio 10/10, Media 3/3,
Display 5/5, Bluetooth 2/2, KeepAwake, Clipboard 5/5, and 3 of 4 SystemMonitor files.

**The list should shrink.** It is the honest measure of the fork boundary, and
each file that leaves it is either an upstream PR that landed or a leak we
learned to route around.

## The psymail path dependency (ccp-8lh)

`Package.swift` gains a dependency upstream does not have:

```swift
.package(path: "../psymail-mini")
```

psymail-mini ships its sources twice — as its own menu-bar app, and as the
`PsymailKit` library. The mail widget embeds the library, so Control Center Pro
carries the inbox rather than launching a second menu-bar app beside its own.

**It is a path, not a URL, and that is a real cost:** a checkout of this repo
alone does not resolve, and CI would need both. The trade was made because the
two repositories move together — every change made to psymail while building a
widget against it would otherwise cost a push, a tag and a bump. When psymail's
embed surface settles, this should become a pinned URL dependency.

The surface itself is one type, `PsymailInbox`, added on the psymail side in
`psy-31y`. Every other psymail type is internal, which is what keeps the seam
one file wide: `Sources/CCPKit/Adapters/MailAdapter.swift` is the only place in
CCP that names PsymailKit at all.
