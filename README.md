# Offline-First Task Board

A Kanban task board (To Do / In Progress / Done) for **iOS** that works fully
offline and synchronizes when connectivity returns — including field-level
conflict resolution, visible per-task sync state, an enforced status workflow,
and a one-tap offline mode for demoing it. The iOS app is the project; a small
bundled server exists so its sync engine has a real contract to run against.

| | |
|---|---|
| **iOS app** | SwiftUI (MV — no ViewModels) · Core Data (programmatic model) · actor-based sync engine · offline queue with field-level conflict resolution · drag & drop + one-tap workflow steps · Swift Testing (63 tests) |
| **Supporting server** | Node.js + Express + SQLite (better-sqlite3), included as the app's sync target · 65 contract tests · zero config |
| **Design docs** | [docs/CLIENT_DESIGN.md](docs/CLIENT_DESIGN.md) — the primary document: app architecture, sync engine, workflow, UI decisions · [docs/BACKEND_DESIGN.md](docs/BACKEND_DESIGN.md) — the wire contract the app is built against (schema, API, sync protocol, conflict matrix, decision log) |

## Running it

**1. Start the supporting server** (Node ≥ 18.17):

```bash
cd backend
npm install
npm start        # http://localhost:4000 — seeds taskboard.db on first boot; logs every request
```

**2. Run the app**: open `frontend/TaskBoard.xcodeproj` in Xcode 16+ (the
project builds in **Swift 6 language mode**), run the `TaskBoard` scheme on any
iOS 17+ simulator. The app talks to `http://localhost:4000` by default. No
other configuration.

**3. Tests**:

```bash
xcodebuild -project frontend/TaskBoard.xcodeproj -scheme TaskBoard \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test   # iOS: 63 tests (or Cmd-U)
cd backend && npm test                  # server contract: 65 tests
```

## A five-minute reviewer tour

1. Launch server + app → the seeded board syncs in.
2. Flip the **offline toggle** in the board header → create and edit tasks →
   orange *pending* badges + "Offline — changes saved locally" banner.
3. While offline, edit a task's title in the app, then edit the **same title**
   from a second client: `./backend/scripts/smoke.sh` shows the curl shapes, e.g.
   `curl -X PATCH localhost:4000/tasks/<id> -H 'content-type: application/json'
   -d '{"baseVersion":<v>,"mutationId":"<uuid>","title":"other device"}'`.
4. Toggle back online → pull down any column to sync → the task gets a red conflict badge and a
   banner; tap the badge → a keep-mine / use-server sheet. Disjoint-field edits
   (title here, description there) merge automatically instead.
5. Delete a task via curl → next sync shows "was deleted on another device"
   with **Restore**. Delete one in-app → same banner offers undo.
6. The **status workflow** is part of the server contract, not just UI:
   columns are adjacent-only (`todo ↔ inProgress ↔ done`, never skipping),
   and every task is born in To Do. In the app, each card offers exactly its
   legal steps as one-tap chips (*Start*, *Complete*, *Reopen*); from curl,
   try the skip the UI won't offer —
   `curl -X PATCH localhost:4000/tasks/<id> -H 'content-type: application/json'
   -d '{"baseVersion":<v>,"mutationId":"<uuid>","status":"done"}'` against a
   `todo` task → **400 `INVALID_TRANSITION`**, nothing applied, no version
   bump. (Offline multi-step moves still work: the queue keeps one column
   step per op and replays them in order.)
7. Chaos-test from the command line (the server's knobs are curl-driven):
   `curl -X PUT localhost:4000/debug/config -H 'content-type: application/json'
   -d '{"latencyMs":0,"failureRate":1,"failMode":"after"}'` — the server commits
   every write but drops the response; watch the app's retries settle
   idempotently (no duplicates, no phantom conflicts). `curl -X POST
   localhost:4000/debug/reset -H 'content-type: application/json' -d
   '{"seed":true}'` demonstrates epoch detection: stale clients discard their
   cursor and resync instead of showing a dead board.

## Important technical decisions

- **MV, not MVVM.** Plain `@Observable` model objects (`Board`,
  `SyncStatusCenter`) that views read directly — the idiom of Apple's own
  samples. No per-screen ViewModels, no view stores a service, no view imports
  Core Data; business logic lives below the view layer and is tested headlessly.
- **Optimistic UI with a reconciling reload.** A user action mutates the
  in-memory board *synchronously* — the tap animates in the same frame — then
  the store write and a debounced reload converge on an identical layout.
  Layout animation is keyed on a structural fingerprint (card id + column), so
  sync echoes that only bump versions never re-animate the board.
- **Offline queue with freeze-after-transmit coalescing.** Edits merge into a
  queued op only while it has never been on the wire; once transmitted it is
  frozen and later edits queue behind it. This one rule eliminates the
  lost-edit and replay-mismatch classes. `baseVersion` binds at send time, so
  sequential offline edits never self-conflict.
- **Core Data with a programmatic model; one background context; one save =
  one transaction.** The pulled rows and the cursor commit atomically; the UI
  consumes value types only. Chosen over SwiftData (weaker transaction/order
  control on Xcode 15) and over GRDB (kept the dependency count at zero).
- **Conflict detection by per-task integer `version`, never by clocks.** Every
  update carries the `baseVersion` it was made against; a stale write gets a
  409 carrying the current server row so the client can rebase without another
  round trip. Field-disjoint concurrent edits auto-merge; same-field edits ask
  the user; position conflicts resolve to the server silently. (Design §9.)
- **Exactly-once outcomes under at-least-once delivery.** Client-generated
  UUIDs make create idempotent; DELETE is absorbing; PATCH replays through a
  `mutationId` ledger — so any ambiguous timeout is safely retried with the
  same mutation id. Rebases mint a fresh id (they are new logical mutations).
- **Delta sync via a global integer sequence + in-row tombstones.** Every
  applied mutation bumps a counter inside the same SQLite transaction that
  writes the row, so `GET /tasks?since=cursor` is a race-free, gap-free change
  feed that includes deletions. A `boardEpoch` UUID (rotated on reset) protects
  clients from a wiped server.
- **Fractional base-62 order keys** (same algorithm on both sides): any reorder
  or cross-column move is a single one-row PATCH — offline-safe, no neighbor
  renumbering, no float precision cliff. Order = `(status, orderKey, id)`,
  a pure function of replicated state, so every device renders the same board.
- **The supporting server: Node + Express + better-sqlite3.** The synchronous
  driver makes the seq-allocation-plus-row-write transaction structurally
  atomic — no await can interleave inside it — and reviewers run it with two
  commands.

## Known limitations

- The design system is deliberately light-appearance only; a dark variant is
  a follow-up.
- Polling (foreground, 30 s, post-mutation, reachability), not push; no
  `BGAppRefreshTask` — visibility latency between devices is the pull cadence.
- Delete wins over unseen concurrent edits (deliberate, documented policy —
  the losing edit is surfaced with a Restore affordance, never silently).
- No `orderKey` rebalancing — keys grow ~1 char per repeated same-spot insert;
  unreachable at demo scale; renormalization design documented.
- Tombstones and the mutation ledger are never pruned (bounded by tasks ever
  created; GC + cursor horizon is the named production follow-up).
- Single board, no auth, plain HTTP to localhost (ATS local-networking
  exception); physical devices would need the Mac's LAN IP.
- Full list with rationale: design docs §15 / client doc.

## What I would add with more time

A dark-mode variant of the design system; `BGAppRefreshTask` background sync; long-poll or SSE change notifications
instead of polling; orderKey renormalization; richer conflict UI (field-level
three-way merge view); iPad multi-column layout; UI test pass over the
critical flows; ledger/tombstone GC with a cursor horizon.

## Assumptions

- Single user, single board; multi-**device** sync for that one board is in
  scope (two simulators against one server), multi-user auth is not.
- The "remote service" was to be built, not mocked — it runs locally with
  zero configuration.
- "Reorder" means user-controlled ordering persisted across devices, hence the
  explicit `orderKey` field beyond the spec's minimum field list.
- Timestamps are display data; sync correctness never depends on device
  clocks (versions and server sequence numbers arbitrate everything).
- iOS 17 minimum deployment (Observable macro); built in Swift 6 language
  mode, so Xcode 16 or newer.

## Approximate time spent

Roughly a focused day end to end: ~3.5 h iOS app + tests, ~1 h live
end-to-end verification (two-client conflict/offline/chaos scenarios), ~1 h
documentation; the supporting server took ~4 h (~1.5 h design, ~2.5 h
implementation + tests) — most of that was designing the sync contract the
app is built against.

## AI tools used

AI-assisted tooling was used during development. All architecture decisions,
scope cuts, and the final review are mine.
