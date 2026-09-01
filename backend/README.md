# Task Board — Supporting Server

The auxiliary half of the Offline-First Task Board project: a small local
service that exists so the **iOS app** — the project — has a realistic backend
to sync against. It is the source of truth and conflict **detector** for a
single Kanban board; each client keeps its own sync cursor and offline
mutation queue. Full design rationale:
[`../docs/BACKEND_DESIGN.md`](../docs/BACKEND_DESIGN.md).

## Run

Requires Node.js >= 18.17.

```bash
npm install
npm start        # http://localhost:4000  (PORT=xxxx to override)
```

First boot creates `taskboard.db` (SQLite, WAL mode) and seeds 6 fixture tasks.
Delete the file or `POST /debug/reset` for a fresh board — clients detect either
via the board epoch and resync safely.

```bash
npm test         # 65 tests: contract, validation, sync, idempotency, conflicts, chaos
./scripts/smoke.sh   # curl tour against a running server
```

## API

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Reachability probe: `{ok, boardEpoch, latestSeq}` |
| GET | `/tasks` | Cold fetch: all live tasks + cursor |
| GET | `/tasks?since=N` | Delta: every change with seq > N, **tombstones included** |
| GET | `/tasks/{id}` | One task (tombstones return 200 with `deleted: true`) |
| POST | `/tasks` | Create; idempotent by client-generated UUID (retry → 200) |
| PATCH | `/tasks/{id}` | Edit/move/reorder; needs `baseVersion` + `mutationId` |
| DELETE | `/tasks/{id}` | Tombstone; version-agnostic, absorbing, always 204 |
| GET/PUT | `/debug/config` | Chaos knobs: `latencyMs`, `failureRate`, `failMode` |
| POST | `/debug/reset` | Wipe board, rotate epoch; `{"seed": true}` reseeds |

Errors: `{"error": {"code", "message", "current?"}}` — codes `VALIDATION` 400,
`NOT_FOUND` 404, `VERSION_CONFLICT` 409, `TASK_DELETED` 409, `CURSOR_RESET` 410,
`DEBUG_INJECTED` 503, `INTERNAL` 500. `current` (the full server row) rides on
both 409s so the client can rebase without another round trip.

### Sync in one paragraph

Mutate through POST/PATCH/DELETE (every applied write bumps the task `version`
and the global sequence), then pull `GET /tasks?since=<cursor>` and persist the
returned `latestSeq` as the next cursor. A stale `baseVersion` gets a 409 with
the current row — resolve and retry with a **fresh** `mutationId` (retries of
the *same* attempt reuse the same `mutationId` and replay safely). If
`boardEpoch` changes or you receive 410, drop the cursor and do a full refetch.

### Simulating bad networks

```bash
curl -X PUT localhost:4000/debug/config -H 'content-type: application/json' \
  -d '{"latencyMs": 1500, "failureRate": 0.3, "failMode": "after"}'
```

`failMode: "before"` fails requests before the handler (request lost).
`failMode: "after"` **commits the write, then drops the response** — the
ambiguous applied-but-unacknowledged case that offline-first sync must survive;
watch the client's idempotent retry settle it.

## iOS notes

- ATS: plain HTTP to localhost needs this in the app's `Info.plist`:
  ```xml
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
  ```
- Timestamps are RFC 3339 UTC with exactly 3 fractional digits
  (`2026-08-31T09:12:45.123Z`). Swift's `JSONDecoder .iso8601` strategy fails on
  fractional seconds — use `ISO8601DateFormatter` with
  `[.withInternetDateTime, .withFractionalSeconds]`.
- The wire is lowerCamelCase and the status enum is `todo | inProgress | done`,
  so `enum Status: String, Codable` needs no custom raw values.

## Known limitations

Deliberate scope cuts for a take-home (rationale in the design doc §15):
tombstones/ledger never pruned, no orderKey rebalancing, no pagination, polling
not push, delete wins over unseen concurrent edits, single board, no auth,
localhost only.
