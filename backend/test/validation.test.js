import test from 'node:test'
import assert from 'node:assert/strict'
import { startServer, task, uuid } from './helpers.js'

test('input validation', async (t) => {
  const s = await startServer()
  t.after(() => s.close())

  const expect400 = async (method, path, body, label) => {
    const r = await s.req(method, path, body)
    assert.equal(r.status, 400, label)
    assert.equal(r.body.error.code, 'VALIDATION', label)
  }

  await t.test('title bounds', async () => {
    await expect400('POST', '/tasks', task(1, { title: '' }), 'empty title')
    await expect400('POST', '/tasks', task(1, { title: '   ' }), 'whitespace title')
    await expect400('POST', '/tasks', task(1, { title: 'x'.repeat(501) }), '501-char title')
    const ok = await s.req('POST', '/tasks', task(1, { title: 'x'.repeat(500) }))
    assert.equal(ok.status, 201, '500-char title is legal')
  })

  await t.test('description cap', async () => {
    await expect400('POST', '/tasks', task(2, { description: 'x'.repeat(4001) }), '4001-char description')
  })

  await t.test('status enum is exact', async () => {
    await expect400('POST', '/tasks', task(3, { status: 'in_progress' }), 'snake_case token')
    await expect400('POST', '/tasks', task(3, { status: 'Todo' }), 'wrong case')
  })

  await t.test('id must be a UUID; missing id/title rejected', async () => {
    await expect400('POST', '/tasks', { id: 'nope', title: 'x' }, 'bad uuid')
    await expect400('POST', '/tasks', { title: 'x' }, 'missing id')
    await expect400('POST', '/tasks', { id: uuid(4) }, 'missing title')
  })

  await t.test('orderKey rules', async () => {
    await expect400('POST', '/tasks', task(5, { orderKey: 'a_b' }), 'bad charset')
    await expect400('POST', '/tasks', task(5, { orderKey: 'V0' }), 'trailing zero')
    await expect400('POST', '/tasks', task(5, { orderKey: 'x'.repeat(129) }), 'too long')
  })

  await t.test('createdAt must be parseable ISO-8601 with a real calendar date', async () => {
    await expect400('POST', '/tasks', task(6, { createdAt: 'yesterday' }), 'garbage timestamp')
    await expect400('POST', '/tasks', task(6, { createdAt: '2026-02-30T10:00:00Z' }), 'impossible date must not roll over')
    await expect400('POST', '/tasks', task(6, { createdAt: '2026-13-01T10:00:00Z' }), 'month 13')
  })

  await t.test('null is never a valid field value', async () => {
    await expect400('POST', '/tasks', task(7, { description: null }), 'null description')
    await expect400('PATCH', `/tasks/${uuid(1)}`, { baseVersion: 1, mutationId: uuid(90), title: null }, 'null title')
  })

  await t.test('malformed JSON and non-object bodies', async () => {
    const r = await s.raw('POST', '/tasks', 'not json at all')
    assert.equal(r.status, 400)
    assert.equal(r.body.error.code, 'VALIDATION')
    await expect400('POST', '/tasks', [1, 2, 3], 'array body')
  })

  await t.test('oversized body -> 400', async () => {
    const r = await s.raw('POST', '/tasks', JSON.stringify(task(8, { description: 'x'.repeat(70000) })))
    assert.equal(r.status, 400)
    assert.equal(r.body.error.code, 'VALIDATION')
  })

  await t.test('empty PATCH -> 400', async () => {
    await expect400('PATCH', `/tasks/${uuid(1)}`, { baseVersion: 1, mutationId: uuid(91) }, 'no updatable fields')
    await expect400('PATCH', `/tasks/${uuid(1)}`, { baseVersion: 1, mutationId: uuid(91), version: 9 }, 'server-owned fields do not count')
  })

  await t.test('bad baseVersion / mutationId', async () => {
    await expect400('PATCH', `/tasks/${uuid(1)}`, { baseVersion: 0, mutationId: uuid(92), title: 'x' }, 'baseVersion 0')
    await expect400('PATCH', `/tasks/${uuid(1)}`, { baseVersion: 1.5, mutationId: uuid(92), title: 'x' }, 'fractional baseVersion')
    await expect400('PATCH', `/tasks/${uuid(1)}`, { baseVersion: 1, mutationId: 'nope', title: 'x' }, 'bad mutationId')
  })

  await t.test('bad since -> 400 VALIDATION', async () => {
    const r = await s.req('GET', '/tasks?since=-1')
    assert.equal(r.status, 400)
    assert.equal(r.body.error.code, 'VALIDATION')
    const r2 = await s.req('GET', '/tasks?since=abc')
    assert.equal(r2.status, 400)
    assert.equal(r2.body.error.code, 'VALIDATION')
  })

  await t.test('hostile request framing -> 400 VALIDATION, never 500', async () => {
    const charset = await fetch(`${s.base}/tasks`, {
      method: 'POST',
      headers: { 'content-type': 'application/json; charset=iso-8859-1' },
      body: JSON.stringify(task(20)),
    })
    assert.equal(charset.status, 400)
    assert.equal((await charset.json()).error.code, 'VALIDATION')

    const encoding = await fetch(`${s.base}/tasks`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'content-encoding': 'gzip' },
      body: 'definitely not gzip',
    })
    assert.equal(encoding.status, 400)
    assert.equal((await encoding.json()).error.code, 'VALIDATION')

    const badEscape = await fetch(`${s.base}/tasks/%zz`)
    assert.equal(badEscape.status, 400)
    assert.equal((await badEscape.json()).error.code, 'VALIDATION')

    const h = await s.req('GET', '/health')
    assert.equal(h.status, 200, 'server survived the framing attacks')
  })

  await t.test('failed writes persist nothing', async () => {
    const before = (await s.req('GET', '/tasks')).body
    await s.req('POST', '/tasks', task(9, { status: 'bogus' }))
    const after = (await s.req('GET', '/tasks')).body
    assert.equal(after.latestSeq, before.latestSeq, 'seq unchanged after rejected write')
    assert.equal(after.tasks.length, before.tasks.length)
  })
})
