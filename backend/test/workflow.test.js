import test from 'node:test'
import assert from 'node:assert/strict'
import { startServer, task, uuid } from './helpers.js'

// Workflow rule (§6): a task moves one column at a time, either direction —
// todo ↔ inProgress ↔ done. The server is the authority: a conforming client
// never sends a skip, so INVALID_TRANSITION only ever fires on a rogue client.
test('status workflow — adjacent-only transitions', async (t) => {
  const patch = (s, n, mutation, fields) =>
    s.req('PATCH', `/tasks/${uuid(1)}`, { baseVersion: n, mutationId: uuid(mutation), ...fields })

  await t.test('every legal step applies; every skip is rejected', async () => {
    const cases = [
      { from: 'todo', to: 'inProgress', ok: true },
      { from: 'todo', to: 'done', ok: false },
      { from: 'inProgress', to: 'todo', ok: true },
      { from: 'inProgress', to: 'done', ok: true },
      { from: 'done', to: 'inProgress', ok: true },
      { from: 'done', to: 'todo', ok: false },
    ]
    for (const [i, c] of cases.entries()) {
      const s = await startServer()
      await s.req('POST', '/tasks', task(1, { status: c.from }))
      const r = await patch(s, 1, 100 + i, { status: c.to })
      if (c.ok) {
        assert.equal(r.status, 200, `${c.from} -> ${c.to} is one step`)
        assert.equal(r.body.status, c.to)
        assert.equal(r.body.version, 2)
      } else {
        assert.equal(r.status, 400, `${c.from} -> ${c.to} skips a column`)
        assert.equal(r.body.error.code, 'INVALID_TRANSITION')
        const g = await s.req('GET', `/tasks/${uuid(1)}`)
        assert.equal(g.body.status, c.from, 'rejected move never landed')
        assert.equal(g.body.version, 1, 'no version bump on rejection')
      }
      await s.close()
    }
  })

  await t.test('same-status PATCH is a no-op transition and applies', async () => {
    const s = await startServer()
    await s.req('POST', '/tasks', task(1, { status: 'inProgress' }))
    const r = await patch(s, 1, 110, { status: 'inProgress', orderKey: 'G' })
    assert.equal(r.status, 200, 'reorder within a column is not a transition')
    await s.close()
  })

  await t.test('creation is not a transition: any birth column is legal', async () => {
    const s = await startServer()
    const r = await s.req('POST', '/tasks', task(1, { status: 'done' }))
    assert.equal(r.status, 201)
    assert.equal(r.body.status, 'done')
    await s.close()
  })

  await t.test('version check precedes transition check', async () => {
    // A stale client must get the 409 (with the current row) so it can rebase;
    // judging its transition against a status it has never seen would be wrong.
    // The request is BOTH stale and an illegal skip from the current status
    // (todo -> done), so the two orderings answer differently: version-first
    // says 409, transition-first would say 400 — the test can tell them apart.
    const s = await startServer()
    await s.req('POST', '/tasks', task(1, { status: 'todo' }))
    await patch(s, 1, 120, { status: 'inProgress' }) // v2
    await patch(s, 2, 121, { status: 'todo' })       // v3, back where it started
    const r = await patch(s, 1, 122, { status: 'done' })
    assert.equal(r.status, 409)
    assert.equal(r.body.error.code, 'VERSION_CONFLICT')
    assert.equal(r.body.error.current.version, 3)
    await s.close()
  })

  await t.test('idempotent replay bypasses the transition check', async () => {
    // The ledger answers before any validation. The replayed step (-> done)
    // is ILLEGAL from the row's current status (todo), so a server that
    // checked the transition before the ledger would answer 400 instead of
    // acknowledging the receipt — the test can tell the orderings apart.
    const s = await startServer()
    await s.req('POST', '/tasks', task(1, { status: 'todo' }))
    await patch(s, 1, 130, { status: 'inProgress' }) // v2
    await patch(s, 2, 131, { status: 'done' })       // v3
    await patch(s, 3, 132, { status: 'inProgress' }) // v4
    await patch(s, 4, 133, { status: 'todo' })       // v5
    const replay = await patch(s, 2, 131, { status: 'done' })
    assert.equal(replay.status, 200)
    assert.equal(replay.body.replayed, true)
    assert.equal(replay.body.status, 'todo', 'replay returns the current row, applies nothing')
    await s.close()
  })

  await t.test('a rejected transition writes no ledger receipt', async () => {
    // The same mutationId, corrected to a legal step, must APPLY — if the 400
    // had minted a receipt, this retry would come back replayed instead.
    const s = await startServer()
    await s.req('POST', '/tasks', task(1, { status: 'todo' }))
    const rejected = await patch(s, 1, 140, { status: 'done' })
    assert.equal(rejected.status, 400)
    const retried = await patch(s, 1, 140, { status: 'inProgress' })
    assert.equal(retried.status, 200)
    assert.equal(retried.body.replayed, undefined, 'applied fresh, not acknowledged from the ledger')
    assert.equal(retried.body.status, 'inProgress')
    assert.equal(retried.body.version, 2)
    await s.close()
  })

  await t.test('a rejected transition leaves no trace in the delta feed', async () => {
    const s = await startServer()
    await s.req('POST', '/tasks', task(1, { status: 'todo' }))
    const before = (await s.req('GET', '/tasks')).body.latestSeq
    await patch(s, 1, 140, { status: 'done' })
    const after = await s.req('GET', `/tasks?since=${before}`)
    assert.equal(after.body.latestSeq, before, 'no sequence bump')
    assert.deepEqual(after.body.tasks, [], 'nothing for other clients to pull')
    await s.close()
  })
})
