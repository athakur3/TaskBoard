import test from 'node:test'
import assert from 'node:assert/strict'
import { midpoint, keyAfter, isValidOrderKey } from '../src/orderkey.js'

test('first key in an empty column is V', () => {
  assert.equal(keyAfter(null), 'V')
  assert.equal(keyAfter(''), 'V')
})

test('keyAfter produces a strictly increasing chain', () => {
  let key = keyAfter(null)
  for (let i = 0; i < 100; i++) {
    const next = keyAfter(key)
    assert.ok(next > key, `${next} > ${key}`)
    assert.ok(isValidOrderKey(next))
    key = next
  }
})

test('midpoint is strictly between its bounds and never ends in 0', () => {
  const pairs = [['A', 'B'], ['A', 'C'], ['K', 'KV'], ['V', 'z'], ['8', 'G'], ['a', 'aV'], ['0z', '1']]
  for (const [a, b] of pairs) {
    const m = midpoint(a, b)
    assert.ok(a < m && m < b, `${a} < ${m} < ${b}`)
    assert.ok(!m.endsWith('0'), `${m} must not end in 0`)
  }
})

test('repeated same-boundary inserts stay ordered (degeneration is graceful)', () => {
  let lower = 'A'
  const upper = 'B'
  for (let i = 0; i < 50; i++) {
    const m = midpoint(lower, upper)
    assert.ok(lower < m && m < upper)
    assert.ok(isValidOrderKey(m))
    lower = m
  }
  assert.ok(lower.length <= 60, `key grew to ${lower.length} chars over 50 splits`)
})

test('validation rejects bad keys', () => {
  assert.equal(isValidOrderKey('V'), true)
  assert.equal(isValidOrderKey('A0B'), true)
  assert.equal(isValidOrderKey('V0'), false)
  assert.equal(isValidOrderKey(''), false)
  assert.equal(isValidOrderKey('a_b'), false)
  assert.equal(isValidOrderKey('é'), false)
  assert.equal(isValidOrderKey('x'.repeat(129)), false)
})
