// All /tasks* responses flow through these helpers so the debug failMode=after
// injection can drop the real response AFTER the write committed — the
// deterministic reproduction of the applied-but-unacknowledged scenario (§11).
function sendInjectedAfter(res) {
  res.status(503).json({
    error: {
      code: 'DEBUG_INJECTED',
      message: 'Injected failure after handler (debug failMode=after); any write was committed',
    },
  })
}

export function sendJson(res, status, body) {
  if (res.locals.injectAfter) return sendInjectedAfter(res)
  res.status(status).json(body)
}

export function sendNoContent(res) {
  if (res.locals.injectAfter) return sendInjectedAfter(res)
  res.status(204).end()
}

// `current` is attached exactly for VERSION_CONFLICT and TASK_DELETED (§7).
export function sendError(res, status, code, message, current) {
  if (res.locals.injectAfter) return sendInjectedAfter(res)
  const error = { code, message }
  if (current !== undefined) error.current = current
  res.status(status).json({ error })
}
