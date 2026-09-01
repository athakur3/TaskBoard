# Offline-First Task Board — Sync Contract & Server Design

The supporting half of the project: the iOS app ([CLIENT_DESIGN.md](CLIENT_DESIGN.md)) is the deliverable, and this server exists to give its sync engine a rigorous, real contract to run against. Most of this document *is* that contract — the wire format, API semantics, sync protocol, and conflict matrix the app implements; the server implementation notes are secondary.

## 1. Overview, goals, explicit non-goals

A small, rigorously specified HTTP+JSON service over SQLite that acts as the source of truth and conflict **detector** for a single Kanban board (To Do / In Progress / Done), consumed by an offline-first iOS client. The server keeps **zero per-client state**; each client owns a sync cursor and an offline mutation queue.

**Goals**

- Client-generated UUIDs: identity is born offline.
- Exactly-once *outcomes* under at-least-once delivery: every retry after an ambiguous timeout is safe.
- Delta sync with deletions: a returning client learns everything that changed, including tombstones, via a gap-free integer cursor.
- Deterministic, non-silent conflict handling (versions, never clocks) — the server detects, the client resolves with full information.
- One-row reorders via fractional string keys.
- Survives the hostile demo: two simulators, aggressive airplane-mode toggling, server Ctrl-C mid-request, `POST /debug/reset` between runs.
- Implementable in ~2 hours; runnable with one command; business logic unit-testable against in-memory SQLite.

**Explicit non-goals** (each is a deliberate cut, one line of README each): auth/users/HTTPS (single-user localhost), CORS (iOS URLSession is not a browser), push channels (polling demonstrably syncs two simulators), batch `/sync` endpoint (sequential replay of idempotent ops is equivalent and individually curl-able), pagination (single-user board), tombstone/ledger pruning (no take-home runs 30 days), CRDTs/OT (out of scope at 8–10h), API path versioning, physical-device networking.

---

## 2. Architecture at a glance

Three primitives carry the whole design:

1. **Per-task integer `version`** — optimistic concurrency. A stale write is never applied; every 409 carries the current server row so the client rebases without another round trip.
2. **Global integer `serverSeq`** — a compacted change feed. Every applied mutation increments a singleton counter and stamps the row *in the same SQLite transaction*; SQLite's single-writer serialization makes sequence numbers visible strictly in commit order, so "cursor = highest seq seen" is gap-free with zero extra machinery.
3. **`mutationId` ledger for PATCH** — a retried update whose first attempt landed replays as success instead of a phantom 409. Create is naturally idempotent by task id; delete is absorbing via the tombstone. Only PATCH needs the ledger.

Plus one operational guard: a **`boardEpoch`** UUID, rotated on reset, so clients detect a wiped/reseeded server instead of silently showing a stale board forever.

```mermaid
sequenceDiagram
    participant UI as iOS UI
    participant C as Local store + FIFO queue
    participant S as Server (SQLite)

    UI->>C: create / edit / move / delete (offline)
    Note over C: ops enqueued FIFO with permanent mutationId<br/>per-task state = pending
    Note over C: connectivity returns → sync cycle (push, then pull)

    loop PUSH — drain queue FIFO
        C->>S: op (baseVersion bound at SEND time)
        alt applied or replayed
            S-->>C: 2xx + task row → adopt version, mark synced
        else conflict
            S-->>C: 409 + current server row
            C->>C: rebase disjoint fields / surface overlap
            C->>S: retry with FRESH mutationId (max 3)
        else transient (timeout / 5xx)
            S-->>C: —
            C->>C: backoff, retry SAME mutationId later
        end
    end

    C->>S: PULL GET /tasks?since=cursor
    S-->>C: rows seq > cursor (incl. tombstones), latestSeq, boardEpoch
    C->>C: epoch check; upsert rows without pending ops;<br/>persist cursor = latestSeq atomically with rows
    C-->>UI: per-task badge: synced / pending / failed
```

---

## 3. Stack — decided: Node.js + Express + better-sqlite3

Everything below (DDL, contracts, protocol) is stack-agnostic — plain HTTP + SQLite SQL. The stack decision is Node.js + Express + better-sqlite3; the comparison is kept as the rationale.

| Option | Pros | Cons |
|---|---|---|
| **Node.js + Express + better-sqlite3** | Synchronous SQLite driver makes the single-writer transaction discipline trivial (no `await` can slip inside a transaction); tiny startup; `npm install && npm start` | One `npm install` step; native module compile is a small risk |
| Swift + Vapor + SQLite | Same language as the client; shared model types possible | Multi-minute SPM resolve+build punishes the reviewer; async DB access makes the snapshot/transaction rules easy to get wrong |
| Python + FastAPI + sqlite3 | Readable; stdlib sqlite3 | venv+pip is two commands and a version minefield; async framework over a sync driver invites the same transaction footguns |

**Why Node.js + Express + better-sqlite3:** the synchronous driver structurally guarantees the two invariants this design leans on (seq allocation and row write in one atomic transaction; `latestSeq` read before the delta rows with nothing interleaving). Whatever stack is chosen: one dedicated write path, `PRAGMA busy_timeout=5000`, and **debug latency/failure injection applied strictly outside any DB transaction**. Default port **4000** (`3000` collides with web dev servers; macOS squats 5000/7000), `PORT` env override, documented in README along with the exact start command.

---

## 4. Data model — SQLite DDL

File `taskboard.db`, created and migrated idempotently at boot. Tests run identical DDL against `:memory:`.

```sql
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;

-- Singleton: global change counter + board identity.
CREATE TABLE IF NOT EXISTS sync_state (
  id          INTEGER PRIMARY KEY CHECK (id = 1),
  last_seq    INTEGER NOT NULL DEFAULT 0,
  board_epoch TEXT    NOT NULL              -- UUID; minted at DB creation, rotated by /debug/reset
);

-- One table. Tombstones live in-row (deleted = 1) so a single delta channel
-- carries live changes AND deletions, and the row carries the seq of its last change.
CREATE TABLE IF NOT EXISTS tasks (
  id          TEXT    PRIMARY KEY,          -- client-generated UUIDv4, lowercase canonical
  title       TEXT    NOT NULL CHECK (length(title) BETWEEN 1 AND 500),
  description TEXT    NOT NULL DEFAULT ''  CHECK (length(description) <= 4000),
  status      TEXT    NOT NULL CHECK (status IN ('todo','inProgress','done')),
  order_key   TEXT    NOT NULL CHECK (length(order_key) BETWEEN 1 AND 128),
  version     INTEGER NOT NULL DEFAULT 1,   -- bumped on every applied mutation incl. delete
  deleted     INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0,1)),
  created_at  TEXT    NOT NULL,             -- RFC3339 UTC millis; client-supplied, canonicalized
  updated_at  TEXT    NOT NULL,             -- RFC3339 UTC millis; server-assigned; display-only
  server_seq  INTEGER NOT NULL              -- seq of this row's LATEST change (rewritten each write)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_seq   ON tasks (server_seq);
CREATE INDEX        IF NOT EXISTS idx_tasks_board ON tasks (status, order_key, id) WHERE deleted = 0;

-- Idempotency ledger, PATCH only. No request hash, no stored response:
-- replay returns the row's CURRENT state. Only applied (2xx) outcomes are recorded.
CREATE TABLE IF NOT EXISTS applied_mutations (
  mutation_id TEXT PRIMARY KEY,             -- client UUID, permanent across retries
  task_id     TEXT NOT NULL,
  applied_at  TEXT NOT NULL
);
```

**Mandatory write pattern** — every mutation is ONE transaction (`BEGIN IMMEDIATE` semantics):

```sql
UPDATE sync_state SET last_seq = last_seq + 1 WHERE id = 1 RETURNING last_seq;  -- newSeq
-- INSERT/UPDATE tasks ... SET server_seq = newSeq, version = version + 1, updated_at = now;
-- INSERT INTO applied_mutations (mutation_id, task_id, applied_at) VALUES (...);  -- PATCH only
COMMIT;
```

A crash can never produce a change invisible to the delta feed or an applied write without its ledger receipt. Seed: 6 fixture tasks (fixed UUIDs so README curls work verbatim) inserted only when `tasks` is empty.

---

## 5. Wire format and conventions

- **JSON** everywhere, `Content-Type: application/json; charset=utf-8` on every response including errors. Collections always wrapped in an object, never a bare array.
- **Keys: lowerCamelCase** on the wire (snake_case only inside SQLite). Status enum uses the **same tokens in DB and wire**: `"todo" | "inProgress" | "done"` — chosen so `enum Status: String, Codable { case todo, inProgress, done }` needs zero custom raw values and no mapping layer exists to have bugs.
- **IDs**: UUIDv4, lowercase hyphenated 36-char form; server lowercases on ingest; anything else → 400.
- **Timestamps**: RFC 3339 UTC with **exactly three fractional digits** and literal `Z`: `2026-08-31T09:12:45.123Z`. Never any other shape. `createdAt` is client-supplied on create (offline creation time is real data) and **canonicalized** by the server (parse any valid ISO-8601, re-serialize to the fixed shape; unparseable → 400). `updatedAt` is always server-assigned. **No sync or conflict decision ever reads a timestamp** — they are display data, so client clock skew is harmless. `updatedAt >= createdAt` is *not* guaranteed (an offline-created task can sync later); documented as a non-invariant.
- **Swift Codable recipe (goes in the README, verbatim)**: `JSONDecoder.dateDecodingStrategy = .iso8601` **fails on fractional seconds**. Use `ISO8601DateFormatter` with `[.withInternetDateTime, .withFractionalSeconds]` (or a fixed `DateFormatter` `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`, `en_US_POSIX`, UTC) for both encode and decode. Do not combine `.convertFromSnakeCase` with explicit CodingKeys — the wire is already camelCase, so neither is needed. `deleted` is guaranteed JSON `true`/`false` (serialization layer converts SQLite 0/1). One contract round-trip test pins all of this.
- **Numbers**: `version` and `latestSeq` are JSON integers (int64 range, safe in every parser). `server_seq` is **not** exposed per task — clients need only the top-level cursor.
- **Requests**: unknown body fields are **ignored** (documented); server-owned fields (`version`, `updatedAt`, `deleted`, `serverSeq`) in a request body are ignored, not errors. Absent means "unchanged/default"; JSON `null` is never a valid field value → 400. Malformed JSON → 400. Bodies capped at 64 KB → 400.
- **Validation limits** (mirrored by the client so 400 is unreachable in practice): title 1–500 chars after trim (required), description ≤ 4000, status exact enum, `orderKey` matches `^[0-9A-Za-z]{1,128}$` and does not end in `0`.

**Canonical Task payload** (the one Task schema, used everywhere — fetches, mutation responses, delta rows, 409 envelopes; tombstones are the same shape with `"deleted": true`, content fields still populated):

```json
{
  "id": "7f7a0e2e-1d2b-4b7e-9c3a-2f8e6d4c1a90",
  "title": "Buy milk",
  "description": "2% if they have it",
  "status": "inProgress",
  "orderKey": "hV",
  "version": 3,
  "deleted": false,
  "createdAt": "2026-08-30T18:04:02.911Z",
  "updatedAt": "2026-08-31T10:02:11.456Z"
}
```

---

## 6. API contract

All non-2xx bodies use the error envelope (§7). `500 INTERNAL` possible everywhere, generic message, no stack traces. Injected debug failures use 503 `DEBUG_INJECTED`.

### GET /health
Reachability probe; exempt from chaos injection.
**200** `{"ok": true, "boardEpoch": "e7a1…", "latestSeq": 57}`

### GET /tasks — full fetch and delta sync
Query: `since` (optional non-negative integer cursor).

- **No `since`** (cold start): all **live** tasks ordered by `(status, orderKey, id)`.
- **`since=N`**: every row — **tombstones included** — with `server_seq > N`, ordered by seq ascending.

**Snapshot rule (normative)**: the handler reads `last_seq` into `latestSeq` FIRST, then selects rows `WHERE server_seq > :since AND server_seq <= :latestSeq`. Race-free under any execution model; a write committing mid-request simply lands in the next pull.

**200**
```json
{ "boardEpoch": "e7a1…", "latestSeq": 57,
  "tasks": [ { "…Task…" : "including tombstones when since is present" } ] }
```
**410** `CURSOR_RESET` — `since > latestSeq` (server was reset/recreated under the client). Client runs the cold-start + reconcile flow (§8).
**400** `VALIDATION` — `since` not a non-negative integer.

No pagination: single-user board; documented non-goal.

### GET /tasks/{id}
**200** — the Task, **even if tombstoned** (a tombstone is an answer, not an absence). **404** `NOT_FOUND` — id never existed. Used by the client to re-fetch a task after a terminally failed op; also the reviewer's single-task curl probe.

### POST /tasks — create (idempotent by task id)
```json
{ "id": "7f7a0e2e-…", "title": "Buy milk", "description": "",
  "status": "todo", "orderKey": "V", "createdAt": "2026-08-31T09:12:44.120Z" }
```
Defaults: `description` → `""`, `status` → `"todo"`, `orderKey` omitted → server assigns end-of-column, `createdAt` omitted → server now.

POST deliberately accepts **any** status even though the app only ever creates into To Do: creation is a birth, not a transition — restore (undo of a delete) and lost-create recovery (§8) legitimately re-create a task in the column it already lived in. The workflow rule binds to PATCH only.

- **201** + full Task — inserted, `version: 1`.
- **200** + **current server row** — id already exists (retry after lost response). Body is ignored; **nothing is ever overwritten and a tombstone is never restored by POST** — if the row is meanwhile tombstoned, the 200 carries `"deleted": true` and the client treats the create as acknowledged-then-deleted-remotely. This closes the "network retry undoes another device's deliberate delete" trap.
- **400** `VALIDATION`.

### PATCH /tasks/{id} — edit / move / reorder
Any subset of `title`, `description`, `status`, `orderKey`; plus two mandatory sync fields: `baseVersion` (server version this edit was made against, **bound at send time**, §8) and `mutationId` (UUID minted when the op enters the queue, permanent across retries; a **rebase mints a fresh one** — each rebase is a new logical mutation). A column move sends `status` + `orderKey` together (atomic position group).
```json
{ "baseVersion": 2, "mutationId": "c3d1…", "status": "done", "orderKey": "q3" }
```
- **200** + full Task — applied (`version = baseVersion + 1`, new seq, new `updatedAt`).
- **200** + current row + `"replayed": true` — `mutationId` found in the ledger (retry of an applied write). The write is acknowledged; it is NOT re-executed.
- **409** `VERSION_CONFLICT` + `current` — row live, `version != baseVersion`, mutationId unknown.
- **409** `TASK_DELETED` + `current` tombstone — row is tombstoned; delete already won.
- **404** `NOT_FOUND` — id never existed (distinct from TASK_DELETED so the client can react differently).
- **400** `VALIDATION` — includes **empty field set** ("no updatable fields") so a buggy client can't churn versions with no-op PATCHes.
- **400** `INVALID_TRANSITION` — the **status workflow**: columns are adjacent-only, `todo ↔ inProgress ↔ done`, either direction, never skipping; a same-status PATCH is a reorder, not a transition. Checked **after** the version gate (a stale client gets the 409 + `current` first, so transition validity is always judged against a status the client has seen) and **after** the ledger (a replay returns the stored row and is never re-judged). Nothing is applied: no version bump, no seq, nothing in the delta feed. The client enforces the same table (`TaskStatus.canMove(to:)`) and queues at most one column step per op, so this code — like `VALIDATION` — is unreachable from a conforming client.

### DELETE /tasks/{id} — delete (version-agnostic; delete wins)
No `baseVersion`, no `mutationId` — deletion is explicit destructive intent, wins over concurrent edits, and is absorbing.
- **204**, no body, **in every case**: live row → tombstoned (`version+1`, new seq); already tombstoned → no-op, **no version/seq bump** (retries don't spam the delta feed); unknown id → no-op. A delete retry can never fail, double-apply, or return an undecodable partial body.

### Debug endpoints — see §11.

**Method not matched** → 405; **unknown path** → 404 `NOT_FOUND`.

---

## 7. Error envelope and error codes

Every non-2xx response:

```json
{ "error": {
    "code": "VERSION_CONFLICT",
    "message": "Task modified elsewhere: server version 5, you sent baseVersion 3.",
    "current": { "…full Task or tombstone…" } } }
```

`current` is present **exactly** for `VERSION_CONFLICT` and `TASK_DELETED` (the rebase material, saving a round trip), `null`/absent otherwise. `message` is human-oriented and never parsed.

Eight codes — deliberately few (a Swift client switches on these; everything else reads `message`):

| Code | HTTP | Meaning |
|---|---|---|
| `VALIDATION` | 400 | Bad JSON, bad field, limits exceeded, empty PATCH, bad `since` |
| `INVALID_TRANSITION` | 400 | Status workflow violated: columns are adjacent-only (§6 PATCH) |
| `NOT_FOUND` | 404 | Id never existed / unknown path |
| `VERSION_CONFLICT` | 409 | Live row, stale `baseVersion` |
| `TASK_DELETED` | 409 | Row is a tombstone |
| `CURSOR_RESET` | 410 | `since > latestSeq` — full resync required |
| `DEBUG_INJECTED` | 503 | Chaos middleware fired |
| `INTERNAL` | 500 | Unexpected exception |

---

## 8. Sync protocol

Client state: local task store (UI source of truth), FIFO mutation queue, persisted `cursor` (integer) + `boardEpoch` (string). Each queue entry carries: op type, task id, payload, `mutationId` (minted at enqueue, never changed across retries), and a **`transmitted` bit** (set the first time the op goes on the wire). Per-task UI state falls out directly: **pending** = queued ops exist; **synced** = none queued, last outcome 2xx; **failed** = terminal error or unresolved conflict (badge tappable to resolve/retry) — mapping cleanly onto the spec's required three states.

**Cold start (no cursor):** `GET /tasks` → replace the local synced snapshot; persist `cursor = latestSeq` and `boardEpoch`. Locally created pending tasks stay queued and push next.

**Epoch rule (mandatory):** every pull response's `boardEpoch` is compared to the stored one. On mismatch — or on a 410 `CURSOR_RESET` — the client drops its cursor and all state for previously-synced tasks, keeps pending **creates** of locally-born tasks (re-pushed as creates), drops pending ops on previously-synced tasks (their basis is gone; surface a one-line notice), then runs cold start and reconciles deletions by set-difference (local synced task absent from snapshot and not pending-create → delete locally). This is what makes `POST /debug/reset` and `rm taskboard.db` survivable.

**Sync cycle** (triggers: app foreground, reachability regained, after any local mutation while online, 30 s foreground timer, `BGAppRefreshTask` for the background-sync brownie point). Order is **push, then pull** — pushes are validated against latest server state anyway, so conflicts surface exactly once, and the pull then delivers merged truth including this client's own writes (self-echo reconciles as a version-equal no-op).

**1. Push — drain the queue strictly FIFO per task** (parallelism across different tasks allowed; per task, serialized):

- **`baseVersion` is bound at SEND time** from the local row's last-known server version, and after every 2xx the client adopts the returned `version` — so two sequential offline edits to one task never self-conflict. (Equivalent alternative: coalesce consecutive queued updates per task. Restamp-at-send is the mandatory floor.)
- **Coalescing is legal only for ops never transmitted** (`transmitted == false`): untransmitted create+edits collapse into one create; untransmitted create+delete cancels locally and never hits the wire. **Once an op has been transmitted even once, it is frozen**; later edits/deletes enqueue as separate ops behind it. This single rule kills the lost-edit, resurrected-orphan, and replay-body-mismatch traps identified in design review.
- Per-op outcomes:
  - **2xx** → adopt returned row (authoritative version/timestamps), mark synced, advance.
  - **409** → resolve per the conflict matrix (§9); every 409 settles the op deterministically (rebased-and-retried with a fresh `mutationId`, max 3 attempts, or failed-and-surfaced). The queue never wedges on conflicts.
  - **400 / 404 terminal**: mark the op failed, drop it, hold subsequent queued ops for the **same** task (they were based on the failed state), `GET /tasks/{id}` to refresh that task's local copy, continue replaying ops for **other** tasks. Exception: 404 on a queued op for a locally-born task whose create was lost → re-enqueue as create **only if the op carries content** (title/description); reorder-only ops are dropped.
  - **Network error / timeout / 5xx / injected 503** → transient: leave op queued, mark task failed-transient, exponential backoff (1 s, 2 s, 4 s… cap 60 s), retry later with the **same `mutationId`** — the server's ledger/id-keyed/absorbing semantics make the ambiguous retry safe for every op type.

**2. Pull:** `GET /tasks?since=cursor`. For each returned row, in seq order:
- Task has **queued local ops** → do **not** apply to the visible row and do **not** delete on a tombstone; store the server row as the op's conflict base. The push step adjudicates (a pulled tombstone will surface as `TASK_DELETED` on push — the "deleted on another device" notice, never a silent evaporation of pending typing).
- Otherwise → upsert guarded by `incoming.version > local.version` (re-applying a page after a crash is a no-op); tombstone → delete locally (with a passive notice if on screen).
- Persist `cursor = latestSeq` **in the same local transaction** as the applied rows — "applied but cursor stale" is then the only reachable crash state, and it is harmless.

**Client queue ordering** is by a monotonic local op id (auto-increment), never wall clock — an NTP step backward between offline edits cannot reorder replay. All mutations are **absolute state** (set status = done, set orderKey = "q3"), never relative (move down one) — reapplication is naturally idempotent.

---

## 9. Conflict strategy — resolution matrix

Arbitration is server-side and mechanical (version equality check inside the write transaction — being N versions stale is the same path as one). Resolution is client-side, deterministic, and fed by the `current` row in every 409. `updatedAt` is never consulted — three machines, three clocks.

| # | Conflict | Server behavior | Client resolution | Outcome |
|---|---|---|---|---|
| 1 | **Edit vs edit, disjoint fields** (A: title, B: description) | Second write → 409 `VERSION_CONFLICT` + current | Auto-rebase: re-apply only the fields this client changed onto `current`, fresh `mutationId`, `baseVersion = current.version`, retry (max 3, then failed) | Both edits survive; all devices converge on the merged row |
| 2 | **Edit vs edit, same field** | 409 + current | No auto-clobber: adopt server copy as base, mark task conflicted, preserve local text, surface "edited on another device — keep yours / take theirs"; "keep yours" is an explicit fresh PATCH. Only the **collided** fields go to the user — the op's disjoint remainder (unconflicted text, the position group) stays queued and merges per rule 1 | Deterministic; the losing value is shown, never silently destroyed |
| 3 | **Edit vs delete** (edit arrives at tombstone) | 409 `TASK_DELETED` + tombstone | **Delete wins.** Drop the edit, show non-blocking "'Buy milk' was deleted on another device"; optional "restore as new task" recreates under a **new UUID** | Deletion stays trustworthy; no zombie resurrection path exists |
| 4 | **Delete vs edit** (delete after unseen edit) | DELETE is version-agnostic → always tombstones | Nothing to resolve; other device learns via tombstone in its next pull (rule 3 if it had pending edits) | Delete wins both directions — one consistent, documented policy |
| 5 | **Delete vs delete** | Second delete → 204, no bump | Both mark synced | Pure idempotency; no error, no delta churn |
| 6 | **Create vs create (same id)** | POST on existing id → 200 current row, never overwrites | Treat as acknowledged; reconcile from response | Always a retry in practice (UUIDv4) |
| 7 | **Move vs move (same task)** | Second → 409 (status+orderKey are one atomic overlapping group) | Server position wins **silently** — positions are low-stakes and instantly redoable; prompting is noise. One workflow carve-out: if steps queued *behind* the shed op need its status as their chain link, the status is retained (only the orderKey is shed) so the queue never replays an illegal skip | No half-moves (group travels together); converges |
| 8 | **Move vs edit** | Disjoint field groups | Rule 1 auto-merge: title lands on the moved row. **Rebase guard:** if `current.status` differs from the status the local `orderKey` was computed against, drop `orderKey` from the rebase (it was minted against another column's neighbors) | Both intents survive; no cross-column teleport |
| 9 | **Concurrent reorders, different tasks** | Independent single-row writes; both apply | Nothing to resolve; `(orderKey, id)` total order renders identically everywhere | Convergence, not intent-preservation — documented |
| 10 | **Reorder of a deleted task** | 409 `TASK_DELETED` | Rule 3: drop the reorder, remove locally, notice | Never resurrects a task off a position-only write |

---

## 10. Ordering and reorder semantics

The spec's field list has no order field, so the design adds **`orderKey`**: a client-generated fractional rank over the base-62 alphabet `0-9 < A-Z < a-z` (ASCII order), compared **bytewise** — identical semantics in SQLite BINARY collation, JSON, and Swift `String <` for pure ASCII. Display order = `(status, orderKey, id)` ascending; the id tie-break makes board order a total, deterministic pure function of replicated state, so equal keys from concurrent same-gap inserts are tolerated and render identically on every device.

- **Generation (client-side; server validates regex only):** midpoint algorithm (~30 lines, standard fractional indexing). First task in a column: `"V"`. Append: past the max key. Insert between `a` and `b`: shortest string strictly between. **Generated keys never end in `0`** — the reserved minimum digit guarantees a strictly-between key always exists even for prefix-adjacent neighbors like `"K"`/`"K0"` (the classic edge case).
- **A move or reorder is ONE PATCH** carrying the atomic `status`+`orderKey` group — one row touched, one queue entry, one delta row; no special endpoint, no neighbor rewrites, offline-safe by construction. A position computed against a stale snapshot is still a legal write (documented trade: conflict-free reordering over perfect intent).
- **Server-assigned fallback:** POST without `orderKey` → end of target column, so a minimal client works before implementing fractional indexing.
- **Degeneration:** ~1 char growth per repeated same-boundary insert; 128-char cap unreachable in normal use. **Rebalancing is deliberately not implemented** — the client logs a warning past 40 chars and the README names column renormalization (evenly respaced keys as ordinary versioned PATCHes) as the known follow-up. Design review concluded an implemented rebalance flow costs more risk than it buys in a take-home.
- **Rejected:** doubles (precision cliff at ~50 adjacent splits, float equality flakiness), dense integers (one move rewrites N rows, floods the delta feed, needs a move endpoint), linked lists (cycles under concurrency), server-side ordering (breaks offline).

---

## 11. Debug / simulation endpoints (brownie point)

All in-memory config, reset on restart, applied to `/tasks*` routes only, **outside any DB transaction** (injected latency must never hold the write lock).

- **GET /debug/config** → 200 current knobs. **PUT /debug/config** `{"latencyMs": 1500, "failureRate": 0.3, "failMode": "before"}` → 200 echo. `latencyMs` 0–30000; `failureRate` 0.0–1.0; `failMode` ∈ `"before" | "after"`:
  - `"before"`: 503 injected before the handler — simulates request loss.
  - `"after"`: handler runs, **write commits**, then the 503 is returned and the real response dropped — reproduces the applied-but-unacked scenario deterministically, letting a reviewer watch the ledger/id-keyed replay machinery work instead of relying on airplane-mode timing luck.
- **POST /debug/reset** `{"seed": true}` → 200. Truncates tasks + ledger, resets `last_seq`, **rotates `boardEpoch`**, optionally reseeds fixtures. The epoch rotation is what makes this safe for already-synced simulators (§8).

The app's header offline toggle covers the client side; these server knobs are driven via curl to demo pending/failed/retry states without touching Wi-Fi.

---

## 12. Backend test plan

Store layer tested against `:memory:` SQLite with the production DDL — this is the "testable business logic" story. ~25 minutes of the budget.

1. **Validation:** empty/501-char title, bad status, bad UUID, bad orderKey (charset, trailing `0`), oversized description, malformed JSON, empty PATCH → 400 with correct codes; nothing persisted.
2. **Versioning:** PATCH at wrong baseVersion → 409 + current; correct → version+1; check runs inside the write transaction (two interleaved writers: one wins, one clean 409, never torn state).
3. **Seq/cursor:** every mutation bumps `last_seq` by exactly 1 and stamps the row; `GET /tasks?since=N` returns exactly rows in `(N, latestSeq]`; snapshot rule (latestSeq read first); tombstones appear in deltas; `since > latestSeq` → 410.
4. **Idempotency:** duplicate POST same id → 200 current, one row; POST on tombstone → 200 tombstone, **no restore, no version bump**; PATCH replay via ledger → 200 `replayed`, no re-execution; **interleaved-writer replay** (apply M_A, apply M_B from elsewhere, retry M_A → still 200 replayed, not phantom 409); DELETE ×2 → 204/204, single version bump; DELETE unknown id → 204.
5. **Conflict matrix:** each row of §9 executed in **both arrival orders**, asserting convergence to the identical final row.
6. **Workflow:** every status pair against the adjacency table; check order pinned with order-discriminating scenarios (version-before-transition via a stale skip that is also illegal from *current*; ledger-before-transition via a replay whose step is illegal from *current*); a rejection writes no ledger receipt, bumps nothing, and leaves no delta trace.
7. **Epoch:** reset rotates epoch; post-reset pull with stale cursor → 410 or epoch mismatch detectable.
8. **Contract round-trip:** serialize a task, assert exact timestamp shape (3-digit millis + Z), JSON booleans for `deleted`, camelCase keys — the test the Swift decoder is written against.
9. **README curl script:** the §6 flows runnable verbatim as a smoke test.

---

## 13. Edge-case coverage table

| Edge case | Handling |
|---|---|
| Replay order create→edit→move | Client contract: FIFO per task (parallel across tasks OK). Server: PATCH on unknown id → distinct 404 for recovery. |
| Create-then-delete offline | Untransmitted → cancel locally (documented). Transmitted → create frozen, DELETE queued behind it; DELETE of unknown id → 204, queue never wedges. |
| One failed op damming the queue | Terminal 4xx: fail op, hold same-task ops, continue other tasks. Transient: pause + backoff. Never infinite-retry a 4xx. |
| Idempotent create after timeout | POST keyed by task UUID → 200 current row, never a duplicate, never a hard error. |
| Retried create vs newer edit | POST never overwrites an existing row; returns current; B's edit survives. Stated explicitly in contract. |
| Retried update after timeout | `applied_mutations` ledger → 200 `replayed`; no phantom 409. 409s additionally carry `current` as defense in depth. |
| Idempotent delete retry | 204 absorbing (tombstoned or unknown), no bump. |
| Edit-edit, different fields | 409 + current; client field-merge rebase; both survive (matrix #1). |
| Edit-edit, same field | Surfaced keep-yours/take-theirs; deterministic; no client clocks (matrix #2). |
| Edit-vs-delete | 409 `TASK_DELETED` (distinct from 404) + tombstone; delete wins; edit preserved in notice, optional recreate-as-new-UUID (matrix #3). |
| Delete-vs-edit (stale delete) | Version-agnostic DELETE always succeeds; asymmetry (edits version-checked, deletes not) stated as a decision (matrix #4). |
| Delete-delete | Second → 204, no bump, no feed churn (matrix #5). |
| Move-vs-move | 409 to second; atomic status+orderKey group; server wins silently; single status column ⇒ a task can never be in two columns (matrix #7). |
| Move-vs-edit | Disjoint groups auto-merge, tested both orders; orderKey dropped on cross-column rebase (matrix #8). |
| Concurrent reorders, same column | Commutative single-row writes; `(orderKey, id)` total order; convergence-not-intent documented (matrix #9). |
| Position exhaustion | Base-62 strings: no float cliff; ~1 char growth per split; **rebalance not implemented — accepted limitation** (warning log + documented follow-up; unreachable in any demo). |
| Move into column being reordered | Positions are self-contained scalars, no referential integrity; both writes legal; deterministic merge. |
| Reorder of concurrently deleted task | 409 `TASK_DELETED`; reorder dropped; tombstones permanent ⇒ resurrection-by-position impossible (matrix #10). |
| Delta pull vs concurrent write | latestSeq read first; rows `> since AND <= latestSeq`; SQLite single-writer ⇒ commit-ordered seqs; late write lands in next pull. |
| Client crash before cursor persist | Re-delivery is idempotent (upsert guarded by version); client persists cursor atomically with rows. |
| First-ever sync | No `since` → live tasks + head `latestSeq`; old tombstones never replayed as mystery deletes; empty board → empty array + valid cursor. |
| Cursor older than retained history | **Designed out**: tombstones never pruned (stated non-goal). Reset case covered by epoch + 410. |
| Echo of own writes vs in-flight edit | Pull skips rows for tasks with pending ops (stores as conflict base); own echo is a version-equal no-op. Sync never reverts in-flight typing. |
| Very large backlog | **Accepted limitation**: no pagination; single-user board is bounded and served on localhost; documented with rationale. |
| Clock +2h fast | Versions + server arrival order arbitrate everything; server assigns `updatedAt`/seq; `createdAt` display-only, canonicalized. |
| Clock jumps backward offline | Queue ordered by monotonic local op id, never wall clock — stated client contract. |
| Server killed mid-request | Row + seq + ledger in ONE WAL transaction; no change invisible to the feed; client retry safe via idempotency. |
| Client killed between ack and bookkeeping | Absolute-state mutations only (relative ops forbidden) + ledger replay → resend converges. |
| Mid-batch push death | **Designed out**: no batch endpoint; per-op requests, each one transaction. |
| Malformed/hostile payloads | 400 + machine-readable code, never 500/partial persistence; documented caps; unknown fields ignored; 64 KB body cap. |
| Update of never-existed id | 404 `NOT_FOUND` distinct from 409 `TASK_DELETED` — client re-creates (content ops) vs runs delete policy; no guessing. |
| Multi-device visibility timing | Eventual consistency bounded by pull cadence (foreground, post-push, 30 s timer, BGAppRefresh) — stated in README; debug endpoints demo the windows. |
| N-versions-stale write | Equality check, not off-by-one; rebase loop capped at 3 then failed — no livelock between aggressive writers. |
| Concurrent requests from one client | Server correctness independent of client politeness: serialized transactions, version check inside txn; clean 409, never torn rows. |

---

## 14. Decision log

| Decision | Rejected | Why |
|---|---|---|
| camelCase wire keys; status tokens `todo/inProgress/done` identical in DB and wire | snake_case wire; `in_progress` | Zero Swift CodingKeys/rawValue mapping ⇒ one fewer bug layer; kills the convertFromSnakeCase double-convert trap. |
| `orderKey` as base-62 fractional string, no trailing `0` | Double midpoints; dense ints; linked list | No precision cliff, bytewise-identical ordering across SQLite/JSON/Swift; one-row reorders; ~30 lines. |
| Reorder rebalance **not implemented** (warn + document) | Implemented renormalization flow | Needs ~40 same-boundary inserts to trigger; the flow itself is a cross-device conflict source; review called it overengineered. |
| DELETE version-agnostic, always wins, returns 204 always | baseVersion-checked delete (abort or auto-retry) | Simplest server, delete can never fail or wedge the queue, one consistent delete-wins policy both directions. Cost: a stale delete can destroy an unseen edit — accepted, stated. |
| Tombstones permanent; restore = new UUID (client affordance) | PATCH `deleted:false` resurrection; POST-restores-tombstone | Absorbing tombstones kill the whole zombie class (retry-resurrection, concurrent restorers — two review-identified flaws) for free. |
| Idempotency ledger for **PATCH only**; create keyed by task id; delete absorbing | Ledger for all ops; single `last_mutation_id` column; Idempotency-Key + request hash | Domain-natural keys cover create/delete; ledger table (not single column) closes the interleaved-writer replay window; no request hash ⇒ Swift's nondeterministic JSON key order can't strand retries. |
| Replay returns **current row** + `replayed: true` | Stored-response verbatim replay | No response_body storage; safe because the frozen-after-transmit rule removes the coalesced-body hazard. |
| Only 2xx outcomes ledgered; rebases mint fresh mutationIds | Recording 409s / reusing keys across rebases | Removes the documented livelock ambiguity with two explicit sentences. |
| One `GET /tasks` endpoint (`since` optional), no pagination | Separate `/changes`; paged deltas | One endpoint, less contract; board is bounded; pagination is a `/v2` line in the README. |
| `boardEpoch` + `since > latestSeq → 410` | Tombstone-pruning horizon + 410 | Pruning is dead code in a take-home; epoch catches the *reachable* reset case (`/debug/reset`, `rm taskboard.db`) flagged in review as demo-lethal. |
| No `/v1` path prefix | Path versioning | One known client, 24h deadline; versioning is ceremony here. |
| Unknown request fields ignored; single 400 for all validation | Strict 422 rejection; 415/422/405 taxonomy; details-object taxonomy | Lenient reader + 8 error codes is the budget-honest contract; strictness needs versioning to be safe. |
| `createdAt` client-supplied, server-canonicalized; no skew clamp | Server-assigned createdAt; 5-min clamp | Creation date must not visibly mutate after sync; nothing correctness-bearing reads it, so trusting the client costs nothing. |
| Per-op REST replayed from FIFO queue | Batch `POST /sync`; PUT-upsert collapse | Batch forces partial-application semantics; separate POST/PATCH keeps "create never clobbers" enforceable and enables field-level merge. |
| Field-disjoint auto-merge + surfaced same-field conflicts | Silent whole-object LWW; CRDTs/OT | LWW is the naive clobber the brownie point penalizes; CRDTs are indefensible at 8–10h. |
| Positions auto-resolve to server on conflict; content edits prompt | Prompting on position conflicts | Positions are low-stakes and redoable; prompts there are noise. |
| Seeded 6-task board; fixed UUIDs | Empty first run | Reviewer sees columns/ordering/sync material instantly; README curls work verbatim. |
| Chaos with `failMode: before\|after` | Before-only injection | "after" reproduces applied-but-unacked deterministically — turns the design's best claim into a demo. |
| `server_seq` hidden from Task payload | Exposing it | Client needs only top-level `latestSeq`; version comparison suffices for upsert guards. |
| SQLite file, WAL, single write path, busy_timeout 5000 | In-memory store; Postgres | Restart-durable tombstones/seq (protocol depends on it); zero reviewer setup; single-writer gives commit-ordered seqs for free — Postgres would need commit-order fencing. |

**High-severity review findings — disposition:** reset-strands-cursors → fixed (epoch + 410 + `/debug/reset`); coalescing-after-transmit loses edits / resurrects orphans → fixed (frozen-after-transmit rule); enqueue-time baseVersion self-conflict → fixed (send-time binding, mandatory); request-hash byte-order stranding → fixed by removing hashing entirely. No high-severity flaw is accepted-without-fix.

---

## 15. Known limitations to disclose in the README

- **Tombstones and ledger rows are never pruned** — bounded by tasks ever created on one board; GC + `CURSOR_RESET`-on-horizon is the named production follow-up.
- **No orderKey rebalancing** — keys grow ~1 char per repeated same-spot insert; renormalization design documented, unimplemented (unreachable at demo scale).
- **No pagination** on fetch/delta — fine for a single-user board on localhost.
- **Polling, not push** — visibility latency is the pull cadence; long-poll/SSE named as the upgrade path.
- **Delete wins over unseen concurrent edits** (version-agnostic DELETE) — a deliberate policy, stated so it reads as a decision, not an accident.
- **Concurrent reorders converge but may match neither user's exact intent** — `(orderKey, id)` determinism is the promise.
- **Single board, no auth, plain HTTP on localhost** — iOS needs `NSAllowsLocalNetworking` in Info.plist (snippet in README); physical devices are a non-goal (simulator shares the Mac's loopback).
- `updatedAt >= createdAt` is not guaranteed for offline-created tasks.
- Resetting the server (`/debug/reset` or deleting `taskboard.db`) is safe **because of** the epoch rule; clients discard pending ops on previously-synced tasks when it fires (surfaced, not silent).

---

## 16. Implementation checklist (~2h backend)

| Step | Est. |
|---|---|
| Scaffold: server entry, port/PORT, JSON body handling + 64 KB cap, error envelope helper | 10 min |
| DDL bootstrap (idempotent), WAL/busy_timeout, epoch mint, seed-when-empty | 10 min |
| Store layer: transactional write pattern (seq bump + row + ledger), canonical timestamp serializer, 0/1→bool | 25 min |
| Routes: GET /health, GET /tasks (+`since`, snapshot rule, 410), GET /tasks/{id}, POST, PATCH (ledger check → version check → transition check → apply), DELETE (absorbing 204) | 30 min |
| Validation module (limits, UUID/orderKey regex, enum, empty-PATCH) shared by routes | 10 min |
| Debug: /debug/config (latency/failureRate/failMode middleware, outside transactions), /debug/reset (truncate + epoch rotate + reseed) | 10 min |
| Tests (§12): store unit tests on `:memory:`, conflict matrix both orders, contract round-trip | 25 min |
| README: run command, curl script, Swift decoding recipe, ATS snippet, non-goals & limitations | 10 min |
| **Total** | **~2h 10m** |

Everything past this line is iOS-client budget. The client-side rules this document makes **mandatory** (send-time baseVersion, frozen-after-transmit coalescing, pending-op pull skip, epoch handling, monotonic queue ids, absolute-state ops, terminal-vs-transient error policy) are part of the sync contract and should be copied into the client's design doc verbatim.