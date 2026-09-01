import { ValidationError } from './validation.js'

// In-memory chaos knobs; reset on restart; applied to /tasks* routes only and
// strictly outside any DB transaction (§11).
export function createDebugState() {
  return { latencyMs: 0, failureRate: 0, failMode: 'before' }
}

export function validateDebugConfig(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    throw new ValidationError('body must be a JSON object')
  }
  const out = {}
  if ('latencyMs' in body) {
    if (!Number.isInteger(body.latencyMs) || body.latencyMs < 0 || body.latencyMs > 30000) {
      throw new ValidationError('latencyMs must be an integer between 0 and 30000')
    }
    out.latencyMs = body.latencyMs
  }
  if ('failureRate' in body) {
    if (typeof body.failureRate !== 'number' || Number.isNaN(body.failureRate) || body.failureRate < 0 || body.failureRate > 1) {
      throw new ValidationError('failureRate must be a number between 0.0 and 1.0')
    }
    out.failureRate = body.failureRate
  }
  if ('failMode' in body) {
    if (body.failMode !== 'before' && body.failMode !== 'after') {
      throw new ValidationError('failMode must be "before" or "after"')
    }
    out.failMode = body.failMode
  }
  return out
}

export function chaosMiddleware(state) {
  return (req, res, next) => {
    const fire = state.failureRate > 0 && Math.random() < state.failureRate
    const proceed = () => {
      if (fire && state.failMode === 'before') {
        return res.status(503).json({
          error: { code: 'DEBUG_INJECTED', message: 'Injected failure before handler (debug failMode=before)' },
        })
      }
      if (fire) res.locals.injectAfter = true
      next()
    }
    if (state.latencyMs > 0) setTimeout(proceed, state.latencyMs)
    else proceed()
  }
}
