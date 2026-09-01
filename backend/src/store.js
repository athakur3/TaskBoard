import { randomUUID } from 'node:crypto'
import { nowIso } from './time.js'
import { keyAfter } from './orderkey.js'
import { ValidationError, canTransition } from './validation.js'

// Fixed UUIDs so the README curl examples work verbatim against a seeded board.
const FIXTURES = [
  { id: '00000000-0000-4000-8000-000000000001', title: 'Sketch board layout', description: 'Three columns: To Do, In Progress, Done.', status: 'todo', orderKey: '8', createdAt: '2026-08-29T09:15:00.000Z' },
  { id: '00000000-0000-4000-8000-000000000002', title: 'Wire up task details screen', description: 'Edit title, description and status.', status: 'todo', orderKey: 'G', createdAt: '2026-08-29T10:05:00.000Z' },
  { id: '00000000-0000-4000-8000-000000000003', title: 'Add pull-to-refresh', description: '', status: 'todo', orderKey: 'V', createdAt: '2026-08-30T08:30:00.000Z' },
  { id: '00000000-0000-4000-8000-000000000004', title: 'Build sync engine', description: 'Push the offline queue, then delta pull.', status: 'inProgress', orderKey: '8', createdAt: '2026-08-29T14:00:00.000Z' },
  { id: '00000000-0000-4000-8000-000000000005', title: 'Design offline badges', description: 'Pending / synced / failed states per task.', status: 'inProgress', orderKey: 'G', createdAt: '2026-08-30T11:45:00.000Z' },
  { id: '00000000-0000-4000-8000-000000000006', title: 'Project scaffolding', description: 'Xcode project plus local server folder.', status: 'done', orderKey: '8', createdAt: '2026-08-28T16:20:00.000Z' },
]

export function createStore(db) {
  const stmts = {
    bumpSeq: db.prepare('UPDATE sync_state SET last_seq = last_seq + 1 WHERE id = 1 RETURNING last_seq'),
    meta: db.prepare('SELECT last_seq, board_epoch FROM sync_state WHERE id = 1'),
    byId: db.prepare('SELECT * FROM tasks WHERE id = ?'),
    live: db.prepare('SELECT * FROM tasks WHERE deleted = 0 ORDER BY status, order_key, id'),
    delta: db.prepare('SELECT * FROM tasks WHERE server_seq > ? AND server_seq <= ? ORDER BY server_seq'),
    maxKeyInColumn: db.prepare('SELECT MAX(order_key) AS k FROM tasks WHERE deleted = 0 AND status = ?'),
    insert: db.prepare(`INSERT INTO tasks (id, title, description, status, order_key, version, deleted, created_at, updated_at, server_seq)
                        VALUES (@id, @title, @description, @status, @order_key, 1, 0, @created_at, @updated_at, @server_seq)`),
    update: db.prepare(`UPDATE tasks SET title = @title, description = @description, status = @status, order_key = @order_key,
                        version = @version, updated_at = @updated_at, server_seq = @server_seq WHERE id = @id`),
    tombstone: db.prepare('UPDATE tasks SET deleted = 1, version = version + 1, updated_at = ?, server_seq = ? WHERE id = ?'),
    ledgerGet: db.prepare('SELECT task_id FROM applied_mutations WHERE mutation_id = ?'),
    ledgerPut: db.prepare('INSERT INTO applied_mutations (mutation_id, task_id, applied_at) VALUES (?, ?, ?)'),
    truncateTasks: db.prepare('DELETE FROM tasks'),
    truncateLedger: db.prepare('DELETE FROM applied_mutations'),
    resetSeq: db.prepare('UPDATE sync_state SET last_seq = 0, board_epoch = ? WHERE id = 1'),
    countTasks: db.prepare('SELECT COUNT(*) AS n FROM tasks'),
  }

  // Mandatory write pattern (§4): seq bump + row write (+ ledger receipt) in
  // ONE transaction. better-sqlite3 transactions are synchronous, so nothing
  // can interleave between seq allocation and the row write.

  // POST semantics (§6): idempotent by task id. An existing row — live or
  // tombstoned — is returned untouched; POST never overwrites and never
  // restores a tombstone.
  const create = db.transaction((input) => {
    const existing = stmts.byId.get(input.id)
    if (existing) return { outcome: 'exists', row: existing }
    const orderKey = input.orderKey ?? keyAfter(stmts.maxKeyInColumn.get(input.status).k)
    if (orderKey.length > 128) {
      // The column's max key is already at the cap, so no end-of-column key
      // exists. Throwing rolls the transaction back; the route maps this to
      // 400 VALIDATION instead of tripping the DDL CHECK into a 500.
      throw new ValidationError('column order space is exhausted at the end; supply an explicit orderKey')
    }
    const seq = stmts.bumpSeq.get().last_seq
    const now = nowIso()
    stmts.insert.run({
      id: input.id,
      title: input.title,
      description: input.description,
      status: input.status,
      order_key: orderKey,
      created_at: input.createdAt ?? now,
      updated_at: now,
      server_seq: seq,
    })
    return { outcome: 'created', row: stmts.byId.get(input.id) }
  })

  // PATCH semantics (§6): ledger check -> existence -> tombstone -> version ->
  // transition -> apply. Version before transition: a stale client gets the
  // 409 (with the current row) first, so transition validity is always judged
  // against a status the client has actually seen.
  const update = db.transaction((id, { baseVersion, mutationId, fields }) => {
    const receipt = stmts.ledgerGet.get(mutationId)
    if (receipt) {
      const row = stmts.byId.get(receipt.task_id)
      if (row) return { outcome: 'replayed', row }
    }
    const row = stmts.byId.get(id)
    if (!row) return { outcome: 'not_found' }
    if (row.deleted === 1) return { outcome: 'deleted', row }
    if (row.version !== baseVersion) return { outcome: 'version_conflict', row }
    if (fields.status !== undefined && !canTransition(row.status, fields.status)) {
      return { outcome: 'invalid_transition', row }
    }
    const seq = stmts.bumpSeq.get().last_seq
    const now = nowIso()
    stmts.update.run({
      id,
      title: fields.title ?? row.title,
      description: fields.description ?? row.description,
      status: fields.status ?? row.status,
      order_key: fields.orderKey ?? row.order_key,
      version: row.version + 1,
      updated_at: now,
      server_seq: seq,
    })
    stmts.ledgerPut.run(mutationId, id, now)
    return { outcome: 'applied', row: stmts.byId.get(id) }
  })

  // DELETE semantics (§6): version-agnostic, absorbing. Tombstoning a live row
  // bumps version and seq once; repeats and unknown ids are silent no-ops.
  const remove = db.transaction((id) => {
    const row = stmts.byId.get(id)
    if (!row || row.deleted === 1) return { outcome: 'noop' }
    const seq = stmts.bumpSeq.get().last_seq
    stmts.tombstone.run(nowIso(), seq, id)
    return { outcome: 'deleted' }
  })

  const reset = db.transaction((seed) => {
    stmts.truncateTasks.run()
    stmts.truncateLedger.run()
    stmts.resetSeq.run(randomUUID())
    if (seed) seedFixtures()
    return meta()
  })

  function meta() {
    const m = stmts.meta.get()
    return { lastSeq: m.last_seq, boardEpoch: m.board_epoch }
  }

  function seedFixtures() {
    for (const fixture of FIXTURES) create(fixture)
  }

  function seedIfEmpty() {
    if (stmts.countTasks.get().n === 0) seedFixtures()
  }

  return {
    create,
    update,
    remove,
    reset,
    meta,
    seedIfEmpty,
    listLive: () => stmts.live.all(),
    delta: (since, latestSeq) => stmts.delta.all(since, latestSeq),
    getById: (id) => stmts.byId.get(id),
  }
}
