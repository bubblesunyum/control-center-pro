# Lifted from .claude/agents/reviewer-correctness.md by harness migrate: the lines below occur in
# that file but not in the shared prompt. Prune what the shared
# prompt now covers; keep only this project's own checks.
effort: low
- **Concurrency.** Work touching shared state from the wrong thread or context,
  captures that outlive what they captured, tasks whose lifetime exceeds the
  thing that spawned them.
  in a closure, setup work that re-runs or never runs, retain cycles.
- **Optionals and boundaries.** Force unwraps, unchecked indexing, and anything
  parsing input that arrives from outside — it will arrive malformed and the
  parser has to survive it.
- **Async correctness.** Missing awaits, unhandled cancellation, races between a
  refresh and a user action, work that assumes ordering it doesn't have.
- **The build itself.** Whatever step a new source file needs before it is
  actually in the binary. If the diff adds files, check that.
And the traps this project specifically sets:
- **Panel lifecycle.** A widget that samples after `deactivate()`, or a timer /
  `Task` / KVO observation the panel's close path never tears down. Idle CPU
  with the panel shut is a shipped requirement, so a leaked sampler is a defect,
  not a nit. Check that every `activate()` has a symmetric `deactivate()` and
  that re-opening doesn't stack a second observer.
- **Main-actor discipline.** Engine sampling belongs off the main thread and
  models publish on it. Look for `@MainActor` state mutated from a detached
  task, `@Observable` models written from a background queue, and `nonisolated`
  used to silence a warning rather than to state a fact.
- **Upstream boundary.** Any diff touching `Sources/Vorssaint/**`,
  `Sources/VMStatisticsCompat`, `Sources/FanControlHelper`, `Tools/`, or
  `Resources/` is a finding on its own — that is the vendored fork and editing
  it makes the next `merge upstream/main` expensive. Same for CCP UI importing
  an upstream type directly instead of going through a CCPKit adapter.
- **AppKit/SwiftUI seams.** `NSPanel` and `NSStatusItem` work is full of them:
  a global `NSEvent` monitor added and never removed, a window retained by its
  own delegate, a status item whose button target outlives it, frame math done
  in the wrong coordinate space or against `NSScreen.main` when the panel
  belongs to the screen the status item is on.
- **Multi-display and geometry.** Anchoring that assumes one screen, a top-right
  origin computed from `frame` where `visibleFrame` was meant (menu bar height),
  a panel wider than the screen it opened on.
- **CoreAudio process taps.** macOS 14.4+ API, and the deepest engine here.
  Availability gates, tap teardown on device change, and what happens when the
  entitlement is missing at runtime rather than at build time.
- **Permissions.** A widget that assumes a permission was granted, or that
  blocks the whole panel when it wasn't. The required behavior is an inline
  degraded state, per widget.
- **Layout persistence.** Codable layout JSON read back after a widget id has
  been renamed or removed — decoding has to survive a layout that references a
  widget the registry no longer has, without dropping the user's whole
  arrangement.
has no test suite and gets exercised by being run, so read it the harder way.
You may run `scripts/verify.sh --quick` to check the tree builds. Don't run the
