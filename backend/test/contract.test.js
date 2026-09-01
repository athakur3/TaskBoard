import test from 'node:test'
import assert from 'node:assert/strict'
import { startServer, task, uuid } from './helpers.js'

const TS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/

test('wire contract', async (t) => {
  const s = await startServer()
  t.after(() => s.close())

  await t.test('health shape', async () => {
    const r = await s.req('GET', '/health')
    assert.equal(r.status, 200)
    assert.equal(r.body.ok, true)
    assert.match(r.body.boardEpoch, /^[0-9a-f-]{36}$/)
    assert.equal(r.body.latestSeq, 0)
  })

  await t.test('created task round-trip: exact timestamp shape, booleans, camelCase, no serverSeq', async () => {
    const r = await s.req('POST', '/tasks', task(1, { description: 'd', status: 'inProgress', orderKey: 'V' }))
    assert.equal(r.status, 201)
    assert.ok(r.contentType.includes('application/json'))
    const tk = r.body
    assert.deepEqual(Object.keys(tk).sort(),
      ['createdAt', 'deleted', 'description', 'id', 'orderKey', 'status', 'title', 'updatedAt', 'version'])
    assert.equal(tk.version, 1)
    assert.equal(tk.deleted, false)
    assert.match(tk.createdAt, TS_RE)
    assert.match(tk.updatedAt, TS_RE)
    assert.equal(tk.status, 'inProgress')
  })

  await t.test('client createdAt is canonicalized, not rejected', async () => {
    const r = await s.req('POST', '/tasks', task(2, { createdAt: '2026-08-31T10:00:00+05:30' }))
    assert.equal(r.status, 201)
    assert.equal(r.body.createdAt, '2026-08-31T04:30:00.000Z')
  })

  await t.test('unknown and server-owned request fields are ignored', async () => {
    const r = await s.req('POST', '/tasks', task(3, { version: 99, deleted: true, serverSeq: 5, wat: 'x' }))
    assert.equal(r.status, 201)
    assert.equal(r.body.version, 1)
    assert.equal(r.body.deleted, false)
  })

  await t.test('uppercase UUIDs are lowercased on ingest', async () => {
    const r = await s.req('POST', '/tasks', { id: uuid(4).toUpperCase(), title: 'Upper' })
    assert.equal(r.status, 201)
    assert.equal(r.body.id, uuid(4))
    const g = await s.req('GET', `/tasks/${uuid(4).toUpperCase()}`)
    assert.equal(g.status, 200)
  })

  await t.test('collections are wrapped in an object, never a bare array', async () => {
    const r = await s.req('GET', '/tasks')
    assert.ok(!Array.isArray(r.body))
    assert.ok(Array.isArray(r.body.tasks))
    assert.equal(typeof r.body.latestSeq, 'number')
    assert.equal(typeof r.body.boardEpoch, 'string')
  })

  await t.test('errors use the envelope and are JSON', async () => {
    const r = await s.req('GET', `/tasks/${uuid(99)}`)
    assert.equal(r.status, 404)
    assert.ok(r.contentType.includes('application/json'))
    assert.equal(r.body.error.code, 'NOT_FOUND')
    assert.equal(typeof r.body.error.message, 'string')
  })

  await t.test('unknown path -> 404, wrong method -> 405', async () => {
    const r = await s.req('GET', '/nope')
    assert.equal(r.status, 404)
    assert.equal(r.body.error.code, 'NOT_FOUND')
    const m = await s.req('PUT', `/tasks/${uuid(1)}`, { title: 'x' })
    assert.equal(m.status, 405)
  })

  await t.test('GET /tasks/:id returns tombstones', async () => {
    await s.req('DELETE', `/tasks/${uuid(1)}`)
    const r = await s.req('GET', `/tasks/${uuid(1)}`)
    assert.equal(r.status, 200)
    assert.equal(r.body.deleted, true)
    assert.equal(r.body.title, 'Task 1', 'tombstone keeps content fields')
  })
})

test('server-assigned end-of-column orderKey fallback', async (t) => {
  const s = await startServer()
  t.after(() => s.close())

  await t.test('keys without orderKey land strictly after the column maximum', async () => {
    const first = await s.req('POST', '/tasks', { id: uuid(10), title: 'first' })
    assert.equal(first.body.orderKey, 'V', 'first key in an empty column')
    const second = await s.req('POST', '/tasks', { id: uuid(11), title: 'second' })
    assert.ok(second.body.orderKey > first.body.orderKey, 'appended after the max')
    await s.req('POST', '/tasks', { id: uuid(12), title: 'high', orderKey: 'y' })
    const third = await s.req('POST', '/tasks', { id: uuid(13), title: 'third' })
    assert.ok(third.body.orderKey > 'y', `server key ${third.body.orderKey} must sort after explicit 'y'`)
    const other = await s.req('POST', '/tasks', { id: uuid(14), title: 'other column', status: 'done' })
    assert.equal(other.body.orderKey, 'V', 'columns are independent order spaces')
  })

  await t.test('order space exhausted at the cap -> 400 VALIDATION, not 500', async () => {
    await s.req('POST', '/tasks', { id: uuid(15), title: 'cap', status: 'inProgress', orderKey: 'z'.repeat(128) })
    const seqBefore = (await s.req('GET', '/health')).body.latestSeq
    const r = await s.req('POST', '/tasks', { id: uuid(16), title: 'overflow', status: 'inProgress' })
    assert.equal(r.status, 400)
    assert.equal(r.body.error.code, 'VALIDATION')
    const seqAfter = (await s.req('GET', '/health')).body.latestSeq
    assert.equal(seqAfter, seqBefore, 'rejected create persisted nothing')
    const explicit = await s.req('POST', '/tasks', { id: uuid(16), title: 'explicit key still works', status: 'inProgress', orderKey: 'z'.repeat(127) + 'y' })
    assert.equal(explicit.status, 201, 'client-supplied key at the cap is still legal')
  })
})
