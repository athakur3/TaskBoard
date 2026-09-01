import test from 'node:test'
import assert from 'node:assert/strict'
import { startServer, task, uuid } from './helpers.js'

test('sequence, cursor and epoch semantics', async (t) => {
  const s = await startServer()
  t.after(() => s.close())

  await t.test('every applied mutation bumps latestSeq by exactly 1', async () => {
    await s.req('POST', '/tasks', task(1))                                                          // seq 1
    await s.req('POST', '/tasks', task(2))                                                          // seq 2
    await s.req('PATCH', `/tasks/${uuid(1)}`, { baseVersion: 1, mutationId: uuid(51), title: 'A2' }) // seq 3
    await s.req('DELETE', `/tasks/${uuid(2)}`)                                                      // seq 4
    const h = await s.req('GET', '/health')
    assert.equal(h.body.latestSeq, 4)
  })

  await t.test('delta returns exactly rows in (since, latestSeq], ordered by seq, tombstones included', async () => {
    const r = await s.req('GET', '/tasks?since=0')
    assert.equal(r.body.tasks.length, 2, 'compacted feed: one row per task')
    assert.deepEqual(r.body.tasks.map((x) => x.id), [uuid(1), uuid(2)])
    assert.equal(r.body.tasks[1].deleted, true)

    const r2 = await s.req('GET', '/tasks?since=3')
    assert.equal(r2.body.tasks.length, 1)
    assert.equal(r2.body.tasks[0].id, uuid(2))
    assert.equal(r2.body.tasks[0].deleted, true)

    const r3 = await s.req('GET', '/tasks?since=4')
    assert.equal(r3.body.tasks.length, 0)
    assert.equal(r3.body.latestSeq, 4)
  })

  await t.test('cold fetch excludes tombstones and orders by (status, orderKey, id)', async () => {
    await s.req('POST', '/tasks', task(3, { status: 'todo', orderKey: 'G' }))
    await s.req('POST', '/tasks', task(4, { status: 'todo', orderKey: '8' }))
    await s.req('POST', '/tasks', task(5, { status: 'done', orderKey: 'V' }))
    const r = await s.req('GET', '/tasks')
    const ids = r.body.tasks.map((x) => x.id)
    assert.ok(!ids.includes(uuid(2)), 'tombstone excluded from cold fetch')
    const doneIdx = ids.indexOf(uuid(5))
    const todo8 = ids.indexOf(uuid(4))
    const todoG = ids.indexOf(uuid(3))
    assert.ok(doneIdx < todo8 && todo8 < todoG, 'bytewise (status, orderKey) order')
  })

  await t.test('since ahead of server -> 410 CURSOR_RESET', async () => {
    const r = await s.req('GET', '/tasks?since=999')
    assert.equal(r.status, 410)
    assert.equal(r.body.error.code, 'CURSOR_RESET')
  })

  await t.test('reset rotates the epoch and restarts the sequence', async () => {
    const before = (await s.req('GET', '/health')).body
    const r = await s.req('POST', '/debug/reset', { seed: true })
    assert.equal(r.status, 200)
    assert.notEqual(r.body.boardEpoch, before.boardEpoch)
    assert.equal(r.body.latestSeq, 6, 'six seeded fixtures')
    const stale = await s.req('GET', `/tasks?since=${before.latestSeq + 5}`)
    assert.equal(stale.status, 410)
  })
})
