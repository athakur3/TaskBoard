# Offline-First Task Board — iOS Client Design

The primary design document for this project — the iOS app is the deliverable;
the bundled server exists to give it a real sync target. Section §8 of
[BACKEND_DESIGN.md](BACKEND_DESIGN.md) pins the wire contract the app is built
against; this document describes the app itself: its architecture, how it
implements that contract, and why the code is shaped the way it is.

## Architecture

```
┌─────────────────────────── SwiftUI ────────────────────────────┐
│  BoardView · TaskDetailView · ConflictView                     │
│        (value types in, intents out — no managed objects)      │
└───────────────▲───────────────────────────────┬────────────────┘
                │ [BoardTask]                    │ intents
┌───────────────┴───────────────┐   ┌───────────▼───────────────┐
│  Board (@MainActor model)     │   │  SyncStatusCenter          │
│  reload on store change       │   │  (@MainActor @Observable)  │
└───────────────▲───────────────┘   └───────────▲───────────────┘
                │                                │ status/notices
┌───────────────┴────────────────────────────────┴───────────────┐
│                     SyncEngine (actor)                          │
│   push: drain queue FIFO → per-op outcome policy (§8)           │
│   pull: delta since cursor → epoch check → guarded upsert       │
│   triggers: foreground · reachability · post-mutation · 30 s    │
└───────▲──────────────────────────────────────────────┬─────────┘
        │ SendContext / outcomes           TaskAPI      │
┌───────┴────────────────────┐   ┌─────────────────────▼─────────┐
│  LocalStore                │   │  URLSessionAPIClient           │
│  Core Data (one background │   │  Endpoint → request<T:Decodable│
│  context = one SQLite txn  │   │  >; status → retryable/validat.│
│  per mutation)             │   │  /conflict/deleted/reset/...   │
└────────────────────────────┘   └───────────────────────────────┘
```

Everything below the observable models is UI-free and tested headlessly. The
composition root (`TaskBoardApp`) builds the graph once; tests build the same
graph with `LocalStore(inMemory: true)` + `MockTaskAPI`.

### Model map (MV — Apple's model-object pattern)

There are no per-screen ViewModels; the app follows the idiom of Apple's own
samples (`FoodTruckModel`, `ModelData`): plain `@Observable` model objects
that views read directly.

| Role | Type |
|---|---|
| App model (domain projection + intents + presentation state) | `Board` — a bare domain noun, like Apple's `Library` |
| Sync status surface | `SyncStatusCenter` |
| Stateless forms (value in, closure out) | `TaskDetailView`, `ConflictView` |
| The model layer beneath | `LocalStore`, `SyncEngine`, `TaskAPI` |

Policy: business logic lives in the model layer; `Board` mediates it for
the views. No view stores `LocalStore`, `TaskAPI`, or `SyncEngine`,
and no view imports Core Data. All wire models (`Models/`, `OpPayload`,
`ConflictRecord`) are `Codable`; every response-bearing request flows through
the one generic `request<T: Decodable>(_ endpoint:)` funnel in
`URLSessionAPIClient`.

## Persistence — Core Data, programmatic model

The model is built in code (`PersistenceController.makeModel()`), not in a
`.xcdatamodeld`: the schema is reviewable in a diff, identical in tests, and
carries no GUI-editor artifacts. Three entities:

| Entity | Role |
|---|---|
| `CDTask` | Local task cache: server fields + `locallyBorn`, `locallyDeleted`, `syncFlag`, `syncedSnapshot` (last server-acked state — the conflict base), `conflictJSON` |
| `CDPendingOp` | The offline queue: monotonic `opId`, kind, absolute-state payload, `mutationId`, `transmitted`, `rebaseCount` |
| `CDSyncMeta` | Singleton: `cursor`, `boardEpoch`, `nextOpId` counter |

All access is serialized through one private-queue context; **every mutation is
one `save()` — one SQLite transaction** — which is what makes "apply pulled rows
and persist the cursor atomically" hold, and why a crash can only ever lose the
in-memory debounce, never invariants. Deleted tasks are *hidden*
(`locallyDeleted`), not removed, until the delete op is acknowledged — frozen
ops behind them still need the row's version base; undo needs its content.

## The §8 mandatory rules, mapped to code and tests

| Rule (design §8) | Implementation | Pinned by |
|---|---|---|
| baseVersion bound at **send** time | `LocalStore.markTransmitted` reads `task.version` in the same transaction that freezes the op | `testDisjointFieldConflictAutoRebasesWithFreshMutationId`, `testSameFieldConflictSurfacesForUserResolution` |
| Coalesce only never-transmitted ops; frozen once on the wire | `updateTask` merges only into an untransmitted tail op; `markTransmitted` sets the bit before the payload is read for send | `testTransmittedOpIsFrozen`, `testEditsCoalesceIntoUntransmittedCreate` |
| create+delete cancels locally | `deleteTask` removes row + ops when an untransmitted create exists | `testCreateThenDeleteCancelsLocally` |
| Monotonic local op ids, never wall clock | `CDSyncMeta.nextOpId` counter assigned inside the write transaction | `testCreateEnqueuesOneOpAndLandsAtColumnEnd` |
| Absolute-state mutations | `OpPayload` carries values, never deltas | (by construction) |
| Transient: keep op, same `mutationId`, backoff | `SyncEngine.handle(.retryable)` aborts the pass; `failureStreak` → exponential `nextAttemptAt` | `testTransientFailureKeepsOpAndSameMutationIdOnRetry` |
| Terminal 4xx: drop op, flag task, hold its queue, roll back to snapshot | `failOpTerminal` (rollback + chain-strip in one transaction; `refreshFromServer` is a freshness bonus) + held-check in `markTransmitted` | `testTerminalValidationFailureDropsOpFlagsTaskAndHoldsQueue`, `testTerminalFailureRollsBackToSnapshotWithoutNetwork` |
| 409 matrix: disjoint auto-rebase (fresh mutationId, ≤3), same-field surfaced, position → server wins silently | `SyncEngine.adjudicateConflict` using `syncedSnapshot` as base | the three conflict tests |
| Delete wins; restore = new UUID | `taskDeletedRemotely` + notice with `restorable`; POST-onto-tombstone treated as acknowledged-then-deleted | `testEditOfRemotelyDeletedTaskDropsWorkAndOffersRestore` |
| Pull skips tasks with queued ops | `applyPull` continues on pending ops / open conflicts | `testPullSkipsTasksWithPendingOps` |
| Upsert guarded by `incoming.version > local.version` | `applyPull` | `testApplyPullUpsertsGuardedByVersion…` |
| Cursor persisted atomically with rows | same `perform` block / save | same test |
| Epoch mismatch or 410 → reset flow, keep locally-born pending creates | `SyncEngine.epochReset` + `LocalStore.applyEpochReset` | `testEpochRotationTriggersResetFlow`, `testEpochResetKeepsLocallyBornCreates…` |
| Push then pull | `syncNow` ordering | `testPullAfterPushDeliversMergedTruth` |

## Sync triggers and the wire budget

Five things request a cycle: launch, foreground return, connectivity
regained, post-mutation, and the 30 s poll. Requests are deliberately hard
to waste (verified against the dev server's request log):

- **Regain means regain**: the reachability handler kicks only on the
  unsatisfied → satisfied *transition* — the monitor's initial "you're
  online" report and same-status path churn buy nothing.
- **Kicks are absorbed, not multiplied**: a kick landing within 2 s of a
  successful cycle with an empty queue is a no-op by definition and is
  dropped; one landing *mid-cycle* is latched and reruns only when queued
  work exists. Launch fires several triggers at once and still produces
  exactly one pull.
- **Test runs are silent**: the test-host app renders inert (spawn-time
  `XCTest*` environment check in `TaskBoardApp`) — a full suite run makes
  zero server requests and never touches the on-disk store.
- **The measured budget**: launch = 1 pull; idle = one poll per 30 s,
  answered `304` with no body (Express ETag + URLSession conditional GETs);
  one user move = 1 PATCH + 1 delta pull. Push-then-pull is the §8 contract —
  the pull returns merged truth, including other devices' changes.

## The status workflow

Columns are **adjacent-only**: `todo ↔ inProgress ↔ done`, either direction,
never skipping — a task reaches Done through In Progress, and Done reopens
only into In Progress. The table lives once on the model
(`TaskStatus.canMove(to:)`) and is mirrored verbatim in the backend contract
(400 `INVALID_TRANSITION`, backend §6) — the server is the authority, the
client just makes the rejection unreachable:

- **Every surface offers only legal targets**: each card carries its legal
  steps as one-tap chips (forward wears the destination column's tint:
  *Start* → In Progress, *Complete* → Done; back steps stay quiet: *Reopen*,
  *← To Do*), and an illegal drag bounces back (every Board intent guards
  with `TaskStatus.canMove(to:)`). The edit sheet edits content only — a save can't smuggle a
  transition. New tasks are **born in To Do** (creation UI offers no column);
  the wire keeps POST permissive because restore and lost-create recovery
  legitimately re-create a task in the column it already lived in — births,
  not transitions.
- **The queue preserves steps**: `applyLocalEdit` never merges a *different*
  status into this task's queued tail op — each op carries at most one column
  (creates keep their birth column, updates hold one adjacent step), so an
  offline To Do → In Progress → Done replays as legal transitions instead of
  collapsing into one illegal skip. Pinned by `TaskWorkflowTests`,
  `testSuccessiveMovesQueueOneWorkflowStepPerOp`, and
  `testMoveBehindUntransmittedCreateQueuesItsOwnStep`.
- **The chain survives conflict handling**: when adjudication sheds an op's
  position (server wins, §9 row 7) or absorbs collided text into a conflict
  record (row 2), a status the steps queued *behind* it still depend on is
  retained as their chain link; a terminal failure rolls the task back to the
  last server-acked snapshot in the same transaction and strips now-illegal
  steps from the held queue. The store, not the debounced UI, is the
  authoritative gate (`moveTask`/`placeTask` re-check inside the
  transaction). Pinned by the three chain-regression tests in
  `SyncEngineTests`.

## Ordering

`Support/OrderKey.swift` is a line-for-line port of the server's base-62
fractional indexing (same first key "V", same no-trailing-zero rule); the two
implementations are pinned to each other by mirrored property tests. Reorders
and moves are single one-row PATCHes carrying the atomic `status`+`orderKey`
group; a move targets the end of the destination column.

## UI decisions

- **Board = horizontal kanban** (tokens in `Support/Theme.swift`): floating
  white cards on a warm paper surface — no column boxes, and the columns
  never repeat their own names: the chip row IS the column header, two-way
  bound to the scroll position (`scrollPosition(id:anchor: .center)`, so the
  chip tracks the column actually in view at every offset) — swiping the
  board moves the selection, tapping a chip scrolls to its column. Each card
  shows
  title / one-line description / sync chip + updated time / its legal
  **workflow step chips**; a dashed *Add a task* row sits under To Do only,
  plus an extended New Task button. Cards **drag & drop** within and across
  columns (`Transferable` task ids; a drop mints one fractional key and ships
  status+orderKey as one atomic op) — the step chips cover the same moves
  non-gesturally, and the context menu keeps Edit/Delete.
- **Move feedback** (every user-made move confirms itself, in the
  destination column's color): the destination chip pulses in its tint and
  both counts roll (`numericText`); the card slides out toward where it went
  and wears a ~2s fading outline where it lands; a light haptic per move (a
  success note on Done); VoiceOver announces "Moved to …"; while dragging,
  only workflow-legal columns show a tinted "drop here" wash. Driven by one
  observable, `Board.lastMove`, set only for local moves that pass the UI's
  legality gate — sync-applied moves stay quiet, Reduce Motion turns slides
  into fades, and the board mutates optimistically (the store write follows;
  in the rare pull-race where its transactional gate refuses, the reload
  reverts the card — the queue itself can never take a skip).
- **UI performance**: a user mutation applies to the in-memory board
  *synchronously* — the tap animates in the same frame; the store write
  follows and the debounced reload reconciles to an identical layout, so
  there is no second visual beat. The board's container animation is keyed
  on a structural fingerprint (card id + column), so sync echoes that bump
  only versions/timestamps never re-animate the layout. The 80 ms reload
  debounce checks `Task.isCancelled` after its sleep — without that guard,
  `try?` swallows the cancellation and every burst becomes a storm of
  immediate reloads.
- **Sync visibility** (a hard requirement): synced is the default state and
  says nothing — badges appear only when something needs attention (orange
  pending / red failed-tappable / red conflict-tappable), the status line
  speaks only in exceptional states (offline banner, syncing spinner, pending
  count), and transient notice banners (deleted-on-another-device with
  Restore, server-reset warnings) carry the rest.
- **Conflicts**: same-field conflicts open a two-version sheet (keep mine /
  use server). The user's text stays visible on the board until they decide;
  nothing is silently destroyed (design §9 row 2).
- **Undo**: deleting posts a notice with Restore — restore recreates under a
  new UUID because tombstones are permanent (design §9 row 3).
- **Empty state**: `ContentUnavailableView` on a genuinely empty board only
  (not while searching, not before first load).
- **Navigation**: the board is the only full screen; every other surface
  (create/edit, conflict) is a subordinate sheet over it, driven by a
  single `Board.presenting: Presentation?` and one exhaustive
  `.sheet(item:)` switch — adding a screen means adding a case the compiler
  forces every switch to handle. Alerts stay outside the enum: they confirm an
  action in place (retry sync), they are not screens. There is deliberately no
  push/drill-down layer yet; when a real one arrives, use
  `NavigationStack(path:)` with a value-typed destination enum and
  `navigationDestination(for:)` rather than growing the sheet enum.
- **Offline toggle** (header): cuts requests off at the client, before the
  socket, so airplane-mode behavior is demoable on demand. (The server's chaos
  knobs are driven via curl — see the reviewer tour.)

## Testing strategy

63 tests (Swift Testing, parallel), no UI tests: the graded logic lives below the view layer.
`LocalStore` runs against real SQLite (`/dev/null` store) so constraint and
transaction semantics are the production ones; `SyncEngine` runs against a
scripted `MockTaskAPI` that can inject any server behavior per request
(conflicts, tombstones, epoch rotation, transient failures). Wire-shape tests
pin the decoder to the server's canonical payloads, including the
fractional-seconds timestamp that Swift's default ISO8601 strategy rejects.
`APIClientErrorMappingTests` pins the HTTP-status → `APIClientError` taxonomy
(the 409 matrix, 410/404/400, the 5xx/unknown fallback) as pure function tests
against the static `mapError`/`decode` — no instance, no network.
