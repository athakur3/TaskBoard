import { canonicalTimestamp } from './time.js'
import { isValidOrderKey } from './orderkey.js'

export const STATUSES = ['todo', 'inProgress', 'done']

// Workflow rule (§6): a task moves one column at a time, in either direction —
// todo ↔ inProgress ↔ done. Skipping a column is INVALID_TRANSITION. The rule
// binds at apply time against the server's current status; clients enforce the
// same table locally, so a rejection here means a non-conforming client.
const TRANSITIONS = {
  todo: ['inProgress'],
  inProgress: ['todo', 'done'],
  done: ['inProgress'],
}

export function canTransition(from, to) {
  return from === to || TRANSITIONS[from].includes(to)
}
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

export class ValidationError extends Error {}

function fail(message) {
  throw new ValidationError(message)
}

export function normalizeUuid(value, name) {
  if (typeof value !== 'string') fail(`${name} must be a UUID string`)
  const v = value.toLowerCase()
  if (!UUID_RE.test(v)) fail(`${name} must be a hyphenated 36-character UUID`)
  return v
}

function checkTitle(value) {
  if (typeof value !== 'string') fail('title must be a string')
  const trimmed = value.trim()
  if (trimmed.length < 1 || trimmed.length > 500) fail('title must be 1-500 characters after trimming')
  return trimmed
}

function checkDescription(value) {
  if (typeof value !== 'string') fail('description must be a string')
  if (value.length > 4000) fail('description must be at most 4000 characters')
  return value
}

function checkStatus(value) {
  if (!STATUSES.includes(value)) fail(`status must be one of: ${STATUSES.join(', ')}`)
  return value
}

function checkOrderKey(value) {
  if (!isValidOrderKey(value)) fail('orderKey must match ^[0-9A-Za-z]{1,128}$ and must not end in "0"')
  return value
}

function requireObject(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) fail('body must be a JSON object')
}

// JSON null is never a valid value for a known field (§5); unknown fields —
// null or otherwise — are ignored.
function rejectNulls(body, keys) {
  for (const key of keys) {
    if (key in body && body[key] === null) fail(`${key} must not be null`)
  }
}

export function validateCreate(body) {
  requireObject(body)
  rejectNulls(body, ['id', 'title', 'description', 'status', 'orderKey', 'createdAt'])
  if (!('id' in body)) fail('id is required (client-generated UUID)')
  if (!('title' in body)) fail('title is required')
  const out = {
    id: normalizeUuid(body.id, 'id'),
    title: checkTitle(body.title),
    description: 'description' in body ? checkDescription(body.description) : '',
    status: 'status' in body ? checkStatus(body.status) : 'todo',
  }
  if ('orderKey' in body) out.orderKey = checkOrderKey(body.orderKey)
  if ('createdAt' in body) {
    const ts = canonicalTimestamp(body.createdAt)
    if (!ts) fail('createdAt must be a valid ISO-8601 timestamp')
    out.createdAt = ts
  }
  return out
}

export function validatePatch(body) {
  requireObject(body)
  rejectNulls(body, ['title', 'description', 'status', 'orderKey', 'baseVersion', 'mutationId'])
  if (!Number.isInteger(body.baseVersion) || body.baseVersion < 1) {
    fail('baseVersion must be a positive integer')
  }
  const mutationId = normalizeUuid(body.mutationId, 'mutationId')
  const fields = {}
  if ('title' in body) fields.title = checkTitle(body.title)
  if ('description' in body) fields.description = checkDescription(body.description)
  if ('status' in body) fields.status = checkStatus(body.status)
  if ('orderKey' in body) fields.orderKey = checkOrderKey(body.orderKey)
  if (Object.keys(fields).length === 0) {
    fail('PATCH must include at least one updatable field (title, description, status, orderKey)')
  }
  return { baseVersion: body.baseVersion, mutationId, fields }
}

export function validateSince(raw) {
  if (raw === undefined) return null
  if (typeof raw !== 'string' || !/^\d+$/.test(raw)) fail('since must be a non-negative integer')
  const n = Number(raw)
  if (!Number.isSafeInteger(n)) fail('since is out of range')
  return n
}
