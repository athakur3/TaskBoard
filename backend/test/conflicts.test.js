import test from 'node:test'
import assert from 'node:assert/strict'
import { startServer, task, uuid } from './helpers.js'

// Server-side rows of the §9 conflict matrix. Client-side resolution
// (field-merge, keep-yours/take-theirs) lives in the iOS app; the server's job
// is: detect via version equality, never apply a stale write, always hand back
// `current` so the client can rebase.
test('conflict matrix — server behavior, both arrival orders', async (t) => {
  await t.test('edit vs edit: first wins, second gets 409 + current', async () => {
    for (const order of ['ab', 'ba']) {
      const s = await startServer()
      await s.req('POST', '/tasks', task(1, { title: 'Base', description: 'base' }))
      const editA = { baseVersion: 1, mutationId: uuid(71), title: 'A title' }
      const editB = { baseVersion: 1, mutationId: uuid(72), description: 'B description' }
      const [first, second] = order === 'ab' ? [editA, editB] : [editB, editA]

      const r1 = await s.req('PATCH', `/tasks/${uuid(1)}`, first)
      assert.equal(r1.status, 200)
      const r2 = await s.req('PATCH', `/tasks/${uuid(1)}`, second)
      assert.equal(r2.status, 409)
      assert.equal(r2.body.error.code, 'VERSION_CONFLICT')
      assert.equal(r2.body.error.current.version, 2, 'current row rides in the 409')

      const final = await s.req('GET', `/tasks/${uuid(1)}`)
      assert.deepEqual(final.body, r1.body, 'row is byte-identical to the winner: stale write was never applied')
      await s.close()
    }
  })

  await t.test('edit vs delete: delete wins in both directions', async () => {
    // Order 1: delete first, then edit -> 409 TASK_DELETED with tombstone
    const s1 = await startServer()
    await s1.req('POST', '/tasks', task(1))
    await s1.req('DELETE', `/tasks/${uuid(1)}`)
    const e1 = await s1.req('PATCH', `/tasks/${uuid(1)}`, { baseVersion: 1, mutationId: uuid(73), title: 'too late' })
    assert.equal(e1.status, 409)
    assert.equal(e1.body.error.code, 'TASK_DELETED')
    assert.equal(e1.body.error.current.deleted, true)
    const g1 = await s1.req('GET', `/tasks/${uuid(1)}`)
    assert.deepEqual(g1.body, e1.body.error.current, 'failed edit left the tombstone untouched')
    assert.equal(g1.body.title, 'Task 1', 'rejected title never landed')
    await s1.close()

    // Order 2: edit first, then a stale delete -> delete still succeeds
    const s2 = await startServer()
    await s2.req('POST', '/tasks', task(1))
    await s2.req('PATCH', `/tasks/${uuid(1)}`, { baseVersion: 1, mutationId: uuid(74), title: 'edited' })
    const d = await s2.req('DELETE', `/tasks/${uuid(1)}`)
    assert.equal(d.status, 204, 'DELETE is version-agnostic')
    const g = await s2.req('GET', `/tasks/${uuid(1)}`)
    assert.equal(g.body.deleted, true)
    await s2.close()
  })

  await t.test('move vs move: status+orderKey travel together; second mover gets 409', async () => {
    const s = await startServer()
    await s.req('POST', '/tasks', task(1, { status: 'todo' }))
    const m1 = await s.req('PATCH', `/tasks/${uuid(1)}`, { baseVersion: 1, mutationId: uuid(75), status: 'inProgress', orderKey: 'G' })
    assert.equal(m1.status, 200)
    assert.equal(m1.body.status, 'inProgress')
    assert.equal(m1.body.orderKey, 'G', 'atomic position group')
    const m2 = await s.req('PATCH', `/tasks/${uuid(1)}`, { baseVersion: 1, mutationId: uuid(76), status: 'done', orderKey: 'V' })
    assert.equal(m2.status, 409)
    const g = await s.req('GET', `/tasks/${uuid(1)}`)
    assert.deepEqual(g.body, m1.body, 'no half-move and no field leakage from the losing move')
    await s.close()
  })

  await t.test('PATCH on a never-existed id is 404, distinct from TASK_DELETED', async () => {
    const s = await startServer()
    const r = await s.req('PATCH', `/tasks/${uuid(42)}`, { baseVersion: 1, mutationId: uuid(77), title: 'x' })
    assert.equal(r.status, 404)
    assert.equal(r.body.error.code, 'NOT_FOUND')
    await s.close()
  })

  await t.test('N-versions-stale write is the same clean 409 as one-stale', async () => {
    const s = await startServer()
    await s.req('POST', '/tasks', task(1))
    let lastApplied = null
    for (let v = 1; v <= 3; v++) {
      lastApplied = await s.req('PATCH', `/tasks/${uuid(1)}`, { baseVersion: v, mutationId: uuid(80 + v), title: `v${v + 1}` })
    }
    const stale = await s.req('PATCH', `/tasks/${uuid(1)}`, { baseVersion: 1, mutationId: uuid(89), title: 'ancient' })
    assert.equal(stale.status, 409)
    assert.equal(stale.body.error.current.version, 4)
    const final = await s.req('GET', `/tasks/${uuid(1)}`)
    assert.deepEqual(final.body, lastApplied.body, 'stale write mutated nothing')
    await s.close()
  })
})
