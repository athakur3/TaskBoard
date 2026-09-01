import express from 'express'
import { createStore } from './store.js'
import { toWire } from './serialize.js'
import { sendJson, sendNoContent, sendError } from './respond.js'
import { validateCreate, validatePatch, validateSince, normalizeUuid, ValidationError } from './validation.js'
import { createDebugState, validateDebugConfig, chaosMiddleware } from './debug.js'

export function createApp(db, { log = false } = {}) {
  const app = express()
  const store = createStore(db)
  const debugState = createDebugState()

  // Dev-server request log (index.js opts in; the test suite stays silent).
  if (log) {
    app.use((req, res, next) => {
      res.on('finish', () => console.log(`${new Date().toISOString().slice(11, 19)}  ${req.method} ${req.originalUrl} → ${res.statusCode}`))
      next()
    })
  }

  app.use(express.json({ limit: '64kb' }))

  // Reachability probe; exempt from chaos injection (§6).
  app.get('/health', (req, res) => {
    const m = store.meta()
    sendJson(res, 200, { ok: true, boardEpoch: m.boardEpoch, latestSeq: m.lastSeq })
  })

  app.use('/tasks', chaosMiddleware(debugState))

  // Full fetch (no `since`) and delta sync (`since=N`, tombstones included).
  // Snapshot rule (§6, normative): read latestSeq FIRST, then select rows
  // bounded by it, so a write committing mid-request lands in the next pull.
  app.get('/tasks', (req, res) => {
    const since = validateSince(req.query.since)
    const m = store.meta()
    if (since === null) {
      return sendJson(res, 200, {
        boardEpoch: m.boardEpoch,
        latestSeq: m.lastSeq,
        tasks: store.listLive().map(toWire),
      })
    }
    if (since > m.lastSeq) {
      return sendError(res, 410, 'CURSOR_RESET',
        `Cursor ${since} is ahead of server sequence ${m.lastSeq}; full resync required`)
    }
    sendJson(res, 200, {
      boardEpoch: m.boardEpoch,
      latestSeq: m.lastSeq,
      tasks: store.delta(since, m.lastSeq).map(toWire),
    })
  })

  // A tombstone is an answer, not an absence (§6).
  app.get('/tasks/:id', (req, res) => {
    const id = normalizeUuid(req.params.id, 'id')
    const row = store.getById(id)
    if (!row) return sendError(res, 404, 'NOT_FOUND', `No task ${id} has ever existed`)
    sendJson(res, 200, toWire(row))
  })

  app.post('/tasks', (req, res) => {
    const input = validateCreate(req.body)
    const { outcome, row } = store.create(input)
    sendJson(res, outcome === 'created' ? 201 : 200, toWire(row))
  })

  app.patch('/tasks/:id', (req, res) => {
    const id = normalizeUuid(req.params.id, 'id')
    const cmd = validatePatch(req.body)
    const result = store.update(id, cmd)
    switch (result.outcome) {
      case 'applied':
        return sendJson(res, 200, toWire(result.row))
      case 'replayed':
        return sendJson(res, 200, { ...toWire(result.row), replayed: true })
      case 'not_found':
        return sendError(res, 404, 'NOT_FOUND', `No task ${id} has ever existed`)
      case 'deleted':
        return sendError(res, 409, 'TASK_DELETED', `Task ${id} was deleted`, toWire(result.row))
      case 'version_conflict':
        return sendError(res, 409, 'VERSION_CONFLICT',
          `Task modified elsewhere: server version ${result.row.version}, you sent baseVersion ${cmd.baseVersion}`,
          toWire(result.row))
      case 'invalid_transition':
        return sendError(res, 400, 'INVALID_TRANSITION',
          `A task cannot move from '${result.row.status}' to '${cmd.fields.status}'; columns are adjacent-only (todo ↔ inProgress ↔ done)`)
    }
  })

  app.delete('/tasks/:id', (req, res) => {
    const id = normalizeUuid(req.params.id, 'id')
    store.remove(id)
    sendNoContent(res)
  })

  app.get('/debug/config', (req, res) => sendJson(res, 200, { ...debugState }))

  app.put('/debug/config', (req, res) => {
    Object.assign(debugState, validateDebugConfig(req.body ?? {}))
    sendJson(res, 200, { ...debugState })
  })

  app.post('/debug/reset', (req, res) => {
    const seed = req.body != null && req.body.seed === true
    const m = store.reset(seed)
    sendJson(res, 200, { ok: true, boardEpoch: m.boardEpoch, latestSeq: m.lastSeq })
  })

  const methodNotAllowed = (req, res) =>
    sendError(res, 405, 'VALIDATION', `${req.method} is not allowed on ${req.path}`)
  app.all('/tasks', methodNotAllowed)
  app.all('/tasks/:id', methodNotAllowed)
  app.all('/debug/config', methodNotAllowed)
  app.all('/debug/reset', methodNotAllowed)

  app.use((req, res) => sendError(res, 404, 'NOT_FOUND', `Unknown path ${req.path}`))

  // eslint-disable-next-line no-unused-vars
  app.use((err, req, res, next) => {
    if (err instanceof ValidationError) return sendError(res, 400, 'VALIDATION', err.message)
    if (err.type === 'entity.parse.failed') return sendError(res, 400, 'VALIDATION', 'Malformed JSON body')
    if (err.type === 'entity.too.large') return sendError(res, 400, 'VALIDATION', 'Body exceeds the 64 KB limit')
    // Hostile request framing (unsupported charset/content-encoding, undecodable
    // percent-escapes in the path, ...) arrives as errors already carrying a 4xx
    // status; the contract folds them all into 400 VALIDATION — never 500 (§13).
    const status = Number(err.status ?? err.statusCode)
    if (err instanceof URIError || (status >= 400 && status < 500)) {
      return sendError(res, 400, 'VALIDATION', 'Unprocessable request framing or body')
    }
    console.error(err)
    sendError(res, 500, 'INTERNAL', 'Internal server error')
  })

  return { app, store }
}
