import test from 'node:test'
import assert from 'node:assert/strict'
import { startServer, task, uuid } from './helpers.js'

test('debug / chaos endpoints', async (t) => {
  const s = await startServer()
  t.after(() => s.close())

  await t.test('config defaults, partial update, validation', async () => {
    const d = await s.req('GET', '/debug/config')
    assert.deepEqual(d.body, { latencyMs: 0, failureRate: 0, failMode: 'before' })

    const u = await s.req('PUT', '/debug/config', { latencyMs: 50 })
    assert.deepEqual(u.body, { latencyMs: 50, failureRate: 0, failMode: 'before' }, 'partial merge')

    for (const bad of [{ latencyMs: -1 }, { latencyMs: 40000 }, { failureRate: 1.5 }, { failMode: 'sideways' }]) {
      const r = await s.req('PUT', '/debug/config', bad)
      assert.equal(r.status, 400, JSON.stringify(bad))
    }
    await s.req('PUT', '/debug/config', { latencyMs: 0 })
  })

  await t.test('failMode=before: request fails, nothing persisted', async () => {
    await s.req('PUT', '/debug/config', { failureRate: 1, failMode: 'before' })
    const r = await s.req('POST', '/tasks', task(1))
    assert.equal(r.status, 503)
    assert.equal(r.body.error.code, 'DEBUG_INJECTED')
    await s.req('PUT', '/debug/config', { failureRate: 0 })
    const g = await s.req('GET', `/tasks/${uuid(1)}`)
    assert.equal(g.status, 404, 'write never happened')
  })

  await t.test('failMode=after: response dropped but the write COMMITTED (applied-but-unacked)', async () => {
    await s.req('PUT', '/debug/config', { failureRate: 1, failMode: 'after' })
    const r = await s.req('POST', '/tasks', task(2))
    assert.equal(r.status, 503)
    assert.equal(r.body.error.code, 'DEBUG_INJECTED')
    await s.req('PUT', '/debug/config', { failureRate: 0 })
    const g = await s.req('GET', `/tasks/${uuid(2)}`)
    assert.equal(g.status, 200, 'the write was committed before the injected failure')
    // and the client retry path settles it idempotently:
    const retry = await s.req('POST', '/tasks', task(2))
    assert.equal(retry.status, 200)
  })

  await t.test('health and debug routes are exempt from chaos', async () => {
    await s.req('PUT', '/debug/config', { failureRate: 1, failMode: 'before' })
    const h = await s.req('GET', '/health')
    assert.equal(h.status, 200)
    const d = await s.req('GET', '/debug/config')
    assert.equal(d.status, 200)
    await s.req('PUT', '/debug/config', { failureRate: 0 })
  })

  await t.test('reset with seed rebuilds the fixture board', async () => {
    const r = await s.req('POST', '/debug/reset', { seed: true })
    assert.equal(r.status, 200)
    const all = await s.req('GET', '/tasks')
    assert.equal(all.body.tasks.length, 6)
    assert.equal(all.body.latestSeq, 6)
    const r2 = await s.req('POST', '/debug/reset', {})
    assert.equal(r2.body.latestSeq, 0, 'reset without seed leaves an empty board')
  })
})
