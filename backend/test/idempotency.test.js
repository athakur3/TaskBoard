import test from 'node:test'
import assert from 'node:assert/strict'
import { startServer, task, uuid } from './helpers.js'

test('idempotency guarantees', async (t) => {
  const s = await startServer()
  t.after(() => s.close())

  await t.test('duplicate POST returns the existing row untouched', async () => {
    const first = await s.req('POST', '/tasks', task(1, { title: 'Original' }))
    assert.equal(first.status, 201)
    const retry = await s.req('POST', '/tasks', task(1, { title: 'Changed on retry' }))
    assert.equal(retry.status, 200)
    assert.equal(retry.body.title, 'Original', 'POST never overwrites')
    assert.equal(retry.body.version, 1)
    const all = await s.req('GET', '/tasks')
    assert.equal(all.body.tasks.filter((x) => x.id === uuid(1)).length, 1)
  })

  await t.test('POST onto a tombstone acknowledges without restoring', async () => {
    await s.req('DELETE', `/tasks/${uuid(1)}`)
    const seqBefore = (await s.req('GET', '/health')).body.latestSeq
    const r = await s.req('POST', '/tasks', task(1, { title: 'Zombie attempt' }))
    assert.equal(r.status, 200)
    assert.equal(r.body.deleted, true, 'create retry cannot undo a delete')
    const seqAfter = (await s.req('GET', '/health')).body.latestSeq
    assert.equal(seqAfter, seqBefore, 'no version/seq churn')
  })

  await t.test('PATCH replay via ledger: 200 replayed, not re-executed, no phantom 409', async () => {
    await s.req('POST', '/tasks', task(2, { title: 'Base' }))
    const m = uuid(61)
    const first = await s.req('PATCH', `/tasks/${uuid(2)}`, { baseVersion: 1, mutationId: m, title: 'Edited' })
    assert.equal(first.status, 200)
    assert.equal(first.body.version, 2)
    const seqBefore = (await s.req('GET', '/health')).body.latestSeq

    const retry = await s.req('PATCH', `/tasks/${uuid(2)}`, { baseVersion: 1, mutationId: m, title: 'Edited' })
    assert.equal(retry.status, 200)
    assert.equal(retry.body.replayed, true)
    assert.equal(retry.body.version, 2)
    const seqAfter = (await s.req('GET', '/health')).body.latestSeq
    assert.equal(seqAfter, seqBefore, 'replay does not bump seq')
  })

  await t.test('interleaved-writer replay: another applied write does not turn a retry into a 409', async () => {
    const mA = uuid(62)
    // M_A applied at v2 -> v3
    const a = await s.req('PATCH', `/tasks/${uuid(2)}`, { baseVersion: 2, mutationId: mA, description: 'from A' })
    assert.equal(a.status, 200)
    // M_B from another device applied at v3 -> v4
    const b = await s.req('PATCH', `/tasks/${uuid(2)}`, { baseVersion: 3, mutationId: uuid(63), title: 'from B' })
    assert.equal(b.status, 200)
    // A's retry of M_A arrives late: must be 200 replayed with CURRENT state, not 409
    const retry = await s.req('PATCH', `/tasks/${uuid(2)}`, { baseVersion: 2, mutationId: mA, description: 'from A' })
    assert.equal(retry.status, 200)
    assert.equal(retry.body.replayed, true)
    assert.equal(retry.body.version, 4, 'replay returns current state')
    assert.equal(retry.body.title, 'from B')
  })

  await t.test('DELETE is absorbing: retries and unknown ids are 204 no-ops', async () => {
    await s.req('POST', '/tasks', task(3))
    const d1 = await s.req('DELETE', `/tasks/${uuid(3)}`)
    assert.equal(d1.status, 204)
    const seqBefore = (await s.req('GET', '/health')).body.latestSeq
    const d2 = await s.req('DELETE', `/tasks/${uuid(3)}`)
    assert.equal(d2.status, 204)
    const d3 = await s.req('DELETE', `/tasks/${uuid(99)}`)
    assert.equal(d3.status, 204)
    const seqAfter = (await s.req('GET', '/health')).body.latestSeq
    assert.equal(seqAfter, seqBefore, 'single version/seq bump per deletion')
    const g = await s.req('GET', `/tasks/${uuid(3)}`)
    assert.equal(g.body.version, 2, 'exactly one bump from the tombstoning')
  })
})
