<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2026 Control Center Pro contributors -->

# Notes storage and sync: plan

Status: **approved with edits, not started.** Written 2026-09-08 (ccp-2zi.4).

This is the build order for the notes storage and Craft sync work, the
reasoning behind it, and the two questions still open. It is self-contained —
you do not need the session that produced it.

It reached this shape through four review rounds; the reasoning that survived
is recorded here, and the discarded designs are not, on purpose.

---

## 1. Two open questions, and what they block

**Neither is answered. Both are the user's call. Ask before step 6.**

### 1.1 Is a note synced to one destination at a time, or several?

The user is seriously considering moving some note-taking to Obsidian
(2026-09-08). That makes a second backend real rather than hypothetical, and
the answer shapes the seam:

- **One at a time** — switching from Craft to Obsidian raises what happens to
  already-mapped notes: re-provision in the new destination, or keep the old
  mapping dormant for a switch back.
- **Several at once** — the seven per-backend `DefaultsMap` keys are *correct*
  rather than sprawl, because each backend owns its own bookkeeping. This would
  also settle §5.2 permanently.

### 1.2 What format does local truth take — one `notes.json`, or a folder of markdown files?

**This blocks step 5's format choice and nothing earlier.** An Obsidian vault
*is* a folder of markdown files. If notes live one-per-file in a folder, that
folder can be both local truth and the vault, and most of the "integration"
disappears. The cost is that selection, tab order, closed tabs and the
pad↔file mapping do not belong in a vault, so it becomes files plus a small
index alongside.

An earlier review recommended a single `notes.json` and called per-note files
over-engineering. That was decided before Obsidian was on the table, and the
premise has changed. Choosing `notes.json` now and moving to files later is a
second data migration on the user's real notes, which is the churn most worth
avoiding.

Steps 1–4 do not depend on the answer. Do them first.

## 2. The one decision already taken

**Keep local truth** (user, 2026-09-08), departing from ccp-2zi.4's written
description, which says the pad "stops storing text in UserDefaults entirely —
no local truth, Craft becomes the store."

Why the bead is wrong:

- ccp-t53p shipped 2026-09-07 (`7a50705`) making the pad optimistically
  editable — `isEditable` unconditionally true, pull demoted to background
  status only. That requires local text.
- `activate()` → `loadApplyingRetention()` (`NotesAdapter.swift:579`) is a
  synchronous read; `apply()` (`:710`) paints in the same frame. CLAUDE.md
  budgets the panel's open under 100ms perceived, which a network read cannot
  meet.
- A user with no Craft credential would have no pad at all.
- `applyRetention` (`:195-202`) clears idle notes. Against a local copy that is
  a tidy-up; against Craft as the store it deletes the user's Craft content on
  a timer.
- The unreadable-bytes rescue path (`:615-629`) only means anything if local
  bytes exist.

**Step 4 rewrites the bead's description.** Until then the ledger asserts the
opposite of the plan.

## 3. Build order

Each step its own commit, gate green (`scripts/verify.sh`), review pass
(`scripts/review.sh` + the reviewer agents). Data-loss first.

### Step 1 — ccp-3me4 (P1): the rescue path loses notes

`rescuedDocument():615` removes the rescue key at `:619` and returns the
document. `loadApplyingRetention` then takes `if loaded == decoded {
lastSavedDocument = loaded }` at `:660` and never persists; `persist:698`
early-returns on equality at `:701`. Result: main key still holds undecodable
bytes, rescue key is gone, the recovered document lives only in memory and dies
on quit.

Worse, the rescue branch never sets `isStoredDocumentUnreadable` (only the
placeholder branch does, at `:655`), so a later user edit reaches `persist:702`,
finds the flag false, skips `rescueUnreadableDocument()`, and writes over the
still-unreadable bytes with no set-aside. Both copies gone.

Fix: persist unconditionally on the rescue branch and set the flag. Add a test
asserting the main key decodes afterward — `NotesDocumentStorageTests:82-94`
asserts consumption but never reads `scratchpadDocument` back.

### Step 2 — ccp-mz2x (P1): a shelf file with no salvageable items is overwritten

`ShelfStore.tolerantLoad` (`:65-66`) returns `wrapped.compactMap(\.item)` with
no emptiness guard, so a file whose every item fails to decode returns `[]`,
never falls through to `load()`, sets nothing aside, and the next
`schedulePersist` writes an empty array over the user's pinned shelf.

`StickyStore.swift:61` already has the guard, with a comment explaining it
("instead of letting the next flush overwrite it with an empty desk"). Copy it.
Two lines. Does **not** wait on step 5.

### Step 3 — three sync-correctness bugs

- **ccp-o2qs** — `CraftPull.swift:83`, `guard !stash.isEmpty else { return
  .adopt(...) }`. A cleared pad yields zero slices; `pushPlan` over zero slices
  is all-removals so the `:79` guard misses it, and the empty stash adopts the
  remote — discarding the user's clear.
- **ccp-i0wm** — `NotesAdapter.swift:1629`. The post-POST re-read bail returns
  after `storeStashIDs` (`:1620`) and `recordConflict` (`:1623`) but before
  `adoptRemote` (`:1640`), so the sidecar never advances; the next `decide`
  sees a differing signature, recomputes "moved", and POSTs a second stash.
  Duplicate copies, not data loss.
- **ccp-5ex4** — `NotesAdapter.swift:1806`. `acceptDrop`'s Task captures
  `target` at `:1805` and spends it at `:1809`; if the note is deleted
  meanwhile, `NotesDocument.appendText` dead-ends on the `firstIndex` guard at
  `:178` and the drop is silently eaten.

### Step 4 — ccp-r3el, and rewrite ccp-2zi.4's description

**Budget ccp-r3el separately — it is not small.** `isPushInFlight` (`:1095`)
guards `pushNow` re-entry only; `pullAll` has no guard. A debounce landing
inside an in-flight pull makes `decide` (`:1596`) compare a half-written remote
against a sidecar captured at `:1232` and not written back until `:1300`/`:1314`
— returning `.conflict` and POSTing a stash whose sidecar the push then
clobbers. Bounded by `stashIDs` persistence to duplicate copies during
sustained overlap, not unbounded growth.

The fix is a shared gate across two independently-cancelled task paths
(`deactivate():594` cancels `pullTask`; the push must not be starved by it).
Distinct from ccp-i0wm, which is pull-internal — same symptom family, different
cause.

Then rewrite ccp-2zi.4's description per §2.

### Step 5 — the `JSONFileStore` rescue capability

Its own bead series, not a sub-step: it changes behaviour for shelf, stickies,
settings and layout, and breaks `JSONFileStoreTests:46` and
`StickyStoreTests:196`.

`JSONFileStore.load()` (`:28-35`) calls `setAside()` on decode failure, and
`setAside()` (`:50-53`) removes any existing `.corrupt` first. Nothing in
`Sources/` ever reads a `.corrupt` file back. Three call-sites have hand-rolled
`tolerantLoad` on top (`ShelfStore:56`, `StickyStore:49`, plus the adapter's
bespoke rescue). Per CLAUDE.md — prefer a flexible capability over a special
case — the capability belongs in `JSONFileStore`:

- **non-destructive read** — a failed decode returns the default and does not
  touch the file;
- **set-aside on write, not read.** `JSONFileStore` is a `struct` with `let`
  storage and a non-mutating `load()`, so it *cannot* remember that a read
  failed. Put the check in `save()`, comparing the on-disk bytes. (An earlier
  draft said "set aside on the first deliberate write" without saying where the
  state lived; it had nowhere to live.)
- **once-only set-aside** — never overwrite an existing `.corrupt`;
- **rescue read-back that persists what it recovers** — step 1's bug, fixed
  once for everyone;
- **per-item tolerant decode**, which needs a same-type-constrained generic
  (`func tolerantLoad<Element>() -> [Element] where Value == [Element], Element:
  Codable`), not a plain member.

`ShelfStore`, `StickyStore` and `SettingsStore` inherit all of it.

If notes later move to a file: `NotesDocument.init(from:)` plain-decodes
`selectedID` at `:87` *before* touching the notes array, so a truncated file —
the common corruption — fails wholesale however leniently the array decodes.
Needs `decodeIfPresent` with a first-note fallback.

**Answer §1.2 before choosing the notes format.**

### Step 6 — split `NotesAdapter.swift`, narrowly

**Not "pure movement" — the obvious split is not behaviour-neutral.** Swift
`private` reaches extensions only within the same file, so moving the AppKit
actions wholesale would force `internal` onto `hasLoaded`, `isReplacingText`,
`document`, `scheduleSave()`, `flushSave()`, `dirtyPadIDs`,
`scheduleCraftPush()`, `defaults`, and the `private(set)` setter on `notes`
(`:282`) — because `appendDroppedText` assigns `notes` at `:1786`, `exportText`
calls `flushSave()`, and `openCraftDocument` calls the private
`storedCraftSpaceID()`, itself called back from `pullAll:1534`. Trading the
adapter's private core for a file boundary is a bad exchange.

Take the clean cuts only:

- **`NotesDocument.swift`** — `:1`–`:255` (`NoteRetention`, `Note`,
  `NotesDocument`, `NotesSupport`). All `public` standalone types, no adapter
  references. `:257`–`:264` is the adapter's own MARK and doc comment; leave it.
- **`NotesAdapter+Actions.swift`** — only what touches no private instance
  state: the `static` drop resolvers (`canResolveDrop`, `droppedText`,
  `loadDropURL/String/Data`, `isDragShim`), the `NSItemProvider` extension,
  `craftDocumentURL`, `openCraft`, `copyAll`. Leave `appendDroppedText`,
  `exportText`, `openCraftDocument` and the space-ID pair behind.

That lifts the `NSPasteboard`/`NSSavePanel`/`NSWorkspace` bulk without widening
anything.

### Step 7 — extract `CraftNoteDestination` as a concrete type

The seven `DefaultsMap`s behind one API. **Keys unchanged, no persisted-format
change, no migration.** `CraftClient`, `CraftBlockSplitter`, `BlockSidecar` and
`CraftPull` stay put; the new type is what stops them being visible above it.

**Hold this invariant — it is what makes a second backend cheap later
(§4.1):** after this step, nothing above `CraftNoteDestination` names a Craft
noun. No `sidecar`, no `documentID`, no block ids, no `stashIDs` in the
adapter's or the UI's vocabulary.

Test surface is 132 lines across eleven accessors (`sidecar(for:` 39,
`craftDocumentID(for:` 18, `storeSidecar` 17, `syncedTitle(for:` 16,
`setCraftDocumentID` 10, `conflicts(for:)` 9, `syncedAt(for:` 8,
`storeSyncedTitle` 7, `stashIDs(for:` 4, `titleRenameDate(for:` 2,
`storeTitleRenameDate` 2). All assert through the adapter; the only
`DefaultsMap` references in tests are a self-contained `DefaultsMapTests` at
`CraftPushTests.swift:529-568`.

One-line forwarding shims keep the suite compiling — but **they are scaffolding,
not the deliverable.** All 33 CCPKit test files use `@testable import`, and
outside the module only `conflicts(for:)` and `dismissConflict` have callers
(`NoteSurface:124, 197, 286, 289, 290`). That leaves twelve `public` accessors
with no external caller; permanent shims would freeze them. State in the commit
that the tests move onto `CraftNoteDestination` in the same or the next commit
and the accessors drop to `internal` on the way. A green gate on a commit whose
tests are unchanged by construction proves the extraction compiled and nothing
else.

Also add the missing observation test. `conflictsVersion` (`:1468-1502`) is a
hand-rolled bump that exists because `DefaultsMap` is invisible to
`@Observable`. The counter is covered (`CraftPullSyncTests:352, 357, 364`); the
`_ = conflictsVersion` **read** at `:1473` — which registers the dependency
`NoteSurface:124, :197` rely on — is not. Assert that reading conflicts
registers a dependency, not that the counter moves.

Then stop and reassess.

## 4. Deferred, with reasoning

### 4.1 The `NoteSyncDestination` protocol

Deferred, **but the reason has changed and so has the follow-up.** It was
deferred because no second backend existed anywhere in the ledger. Obsidian
(§1.1) makes one real. It stays deferred now only because the objections below
are genuine design problems better solved against working code than in another
design document.

What makes adding it later nearly free:

1. **The §3 step 7 invariant.** If no Craft noun escapes the type, adding the
   protocol is mechanical: lift the signatures, change one annotation at the
   composition root, write the new conformance. Zero call-site churn. Every
   leak is a call-site paid for later — which is why narrowing the twelve
   public accessors matters more than its stated reason.
2. **Prove the seam with a second implementation now.** Write
   `FakeNoteDestination` in `CCPKitTests` standing in for Craft across the sync
   tests. If a fake substitutes cleanly the seam is real; if not, the leak is
   found while it is still cheap. This is CLAUDE.md's "mock at the boundary"
   anyway, and it turns "this will be easy later" into something demonstrated.

Obsidian is useful here precisely because it stresses the seam from the
opposite end: Craft is id-heavy with a block model, a vault is paths and files
with no ids at all. A seam serving both extremes is probably a real seam.

**Unresolved objections to the last drafted shape** (a batch
`reconcile(_ notes: [UUID: NoteContents]) async throws -> [UUID: SyncOutcome]`
plus `verify`/`push`/`trash`/`forget`, with `SyncOutcome` of
`converged/adopt/conflicted/gone/skip`). Each was verified against the source:

- `pullOnePad`'s post-fetch re-read (`:1591-1594`) and post-POST re-read
  (`:1628`) are freshness checks against live adapter state. A batch widens the
  window between a pad's decision and its application from one round trip to N,
  and `SyncOutcome` does not carry the local text it decided from, so the guard
  cannot be reproduced at apply time.
- A cancelled round (`deactivate():594` cancels `pullTask`) cannot express
  partial results through `throws -> [UUID: SyncOutcome]`, so stashes already
  POSTed to Craft would be discarded.
- `preserveLocal` cannot be computed by the destination alone:
  `hasUnconfirmedEdits:870` reads `dirtyPadIDs`, which is coordinator state.
- `syncStatus:365-376` reads `craftDocumentID(for:)` **synchronously** inside a
  view body (`NoteSurface:174`); no drafted member serves that.
- Conflict records persist under `scratchpadCraftConflicts`; an in-memory
  observable property on a coordinator would not.

These are coordinator design problems, not Craft problems — an Obsidian backend
faces all five.

### 4.2 Collapsing the seven keys into one `CraftPadRecord`

**Do not do this.** If the record reads empty where the old maps read populated,
`craftDocumentID == nil` sends `pushOnePad:1205` down the provisioning branch
and mints a *second* Craft document for a pad that already had one; or a
surviving docID with an empty sidecar makes `pushPlan` treat every slice as an
insert and re-POST every block into the user's existing document, with the
pull's signature compare then routing to `.conflict` and stashing on top. That
damage lands in the user's Craft account, beyond every CCP rescue key. A single
`[String: CraftPadRecord]` is one atomic decode, so a malformed record does this
for **every pad at once** — the seven-map shape has a blast-radius virtue.

The tidiness it buys is already bought by `dropSyncState(for:)` (`:833-842`).
Same shape as the `a-codable-rename-is-a-data-migration` trap. If §1.1 answers
"several destinations," this is settled permanently: each backend owns its keys.

## 5. Facts worth not rediscovering

- **Retention is dead code, not a live hazard.** Nothing in `Sources/CCPKit`,
  `CCPUI` or `ControlCenterPro` ever *writes* `scratchpadRetention` — only the
  read at `:639` exists, and `sanitized` defaults to `.never`. No user can reach
  a non-never retention, so the "retention over a synced pad" interaction is
  latent-squared. Filed as ccp-56b7: wire a UI (resolving the sync interaction
  first) or delete the read.
- **The `queue: nil` credential observer is safe today, by accident.** Both
  posters of `.craftCredentialDidChange` are `CraftConnectionModel.save():94`
  and `.forget():111`, and that class is `@MainActor`
  (`CraftConnectionModel.swift:27`), so `MainActor.assumeIsolated` at
  `NotesAdapter:524` holds. Nothing enforces it; a future non-main poster traps
  rather than misbehaves. Worth a comment at the post sites.
- **Main-actor network I/O does not hitch the panel.** `CraftClient` is a
  nonisolated `struct: Sendable` (`:48`) and `CraftTransport.data(for:)` is
  nonisolated async (`:37`), so awaiting from `@MainActor` suspends and frees
  the actor. Already true of today's `pullAll`.
- **UserDefaults interop is vestigial.**
  `Vorssaint/Services/QuickTools/ScratchpadService.swift` is in `Package.swift`'s
  exclude list and is not compiled, and per the trap
  `app-defaults-domain-is-the-bundle-id` the two bundle ids give different
  domains. The comment at `NotesAdapter.swift:263` claims a compatibility that
  cannot occur.
- **`Package.swift` is tools-version 5.9 with no strict-concurrency flag.**
  `Sendable` buys warnings, not enforcement. Everything here is `@MainActor`;
  `text.didSet` (`:270-280`) is synchronous and cannot await, and
  `flushSave:690` reads the current document at flush time, so `scheduleSave` is
  order-independent by construction. Do not make local writes async.
- **`NotesDocument` carries a legacy decoding path.** `LegacyCodingKeys`
  (`:76-94`) reads documents written with `notes` instead of `pads`. Any future
  storage type must carry it forward.
- **Write amplification, if notes move to a file.** `scheduleSave` (`:681-688`)
  debounces 800ms; a coalesced defaults write becomes a full encode plus atomic
  file write of every note per tick. Unmeasured.
- **How to prompt the reviewers.** `bd recall
  a-reviewers-verdict-follows-its-prompts-emphasis` — a review agent returns
  the verdict its prompt emphasizes. State the plan plainly, weight all
  verdicts equally, leave the examination areas unranked. Three steered reviews
  of this plan produced three different confident verdicts; the neutral one
  found the implementation defects the others never reached.

## 6. Beads

`ccp-3me4` (P1) · `ccp-mz2x` (P1) · `ccp-o2qs` · `ccp-i0wm` · `ccp-5ex4` ·
`ccp-r3el` · `ccp-56b7` · `ccp-2zi.4` (P0, in progress, description needs the
§2 rewrite) · `ccp-o3k` (pad history — overlaps the preserve-then-adopt path;
`MarkdownNoteEditor`'s `documentId` is `adapter.selectedNoteID?.uuidString`
(`NoteSurface.swift:24`) and MarkdownEngine scopes undo by it, so
`adoptRemote:1730-1745` replaces text under a stack that can walk back into
pre-pull text and push it as if typed).

Steps 5, 6 and 7 need beads filed before their commits — the commit-msg hook
enforces one per commit.
