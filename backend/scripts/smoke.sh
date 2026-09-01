#!/usr/bin/env bash
# Curl tour of the Task Board API (BACKEND_DESIGN.md §6).
# Usage: ./scripts/smoke.sh   (server must be running; BASE overrides the URL)
set -euo pipefail
BASE="${BASE:-http://localhost:4000}"
ID="7f7a0e2e-1d2b-4b7e-9c3a-2f8e6d4c1a90"
MUT_A="c3d1a2b3-0000-4000-8000-000000000001"

step() { printf '\n\n=== %s ===\n' "$1"; }

step "Health"
curl -sf "$BASE/health"

step "Cold fetch (live tasks + cursor)"
curl -sf "$BASE/tasks"

step "Create"
curl -sf -X POST "$BASE/tasks" -H 'content-type: application/json' \
  -d "{\"id\":\"$ID\",\"title\":\"Buy milk\",\"description\":\"2% if they have it\"}"

step "Create retry (idempotent -> 200, never a duplicate)"
curl -s -X POST "$BASE/tasks" -H 'content-type: application/json' \
  -d "{\"id\":\"$ID\",\"title\":\"Buy milk\"}"

step "Edit (PATCH with baseVersion + mutationId)"
curl -s -X PATCH "$BASE/tasks/$ID" -H 'content-type: application/json' \
  -d "{\"baseVersion\":1,\"mutationId\":\"$MUT_A\",\"status\":\"inProgress\",\"orderKey\":\"hV\"}"

step "Replay the same mutation (ledger -> 200 replayed, not 409)"
curl -s -X PATCH "$BASE/tasks/$ID" -H 'content-type: application/json' \
  -d "{\"baseVersion\":1,\"mutationId\":\"$MUT_A\",\"status\":\"inProgress\",\"orderKey\":\"hV\"}"

step "Stale write (baseVersion 1 again, fresh mutationId -> 409 + current)"
curl -s -X PATCH "$BASE/tasks/$ID" -H 'content-type: application/json' \
  -d "{\"baseVersion\":1,\"mutationId\":\"c3d1a2b3-0000-4000-8000-000000000002\",\"title\":\"stale\"}"

step "Delta since 0 (includes every change; then use latestSeq as your next cursor)"
curl -sf "$BASE/tasks?since=0"

step "Delete (204, absorbing)"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X DELETE "$BASE/tasks/$ID"
curl -s -o /dev/null -w 'HTTP %{http_code} (retry)\n' -X DELETE "$BASE/tasks/$ID"

step "Edit the deleted task -> 409 TASK_DELETED (delete wins)"
curl -s -X PATCH "$BASE/tasks/$ID" -H 'content-type: application/json' \
  -d "{\"baseVersion\":2,\"mutationId\":\"c3d1a2b3-0000-4000-8000-000000000003\",\"title\":\"zombie\"}"

step "Cursor ahead of server -> 410 CURSOR_RESET"
curl -s "$BASE/tasks?since=999999"

printf '\n\nSmoke tour complete.\n'
