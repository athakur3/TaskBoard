import { createDb } from '../src/db.js'
import { createApp } from '../src/app.js'

export async function startServer() {
  const db = createDb(':memory:')
  const { app, store } = createApp(db)
  const server = await new Promise((resolve) => {
    const s = app.listen(0, () => resolve(s))
  })
  const base = `http://127.0.0.1:${server.address().port}`
  return {
    base,
    store,
    db,
    close: () => new Promise((resolve) => server.close(resolve)),
    async req(method, path, body) {
      const res = await fetch(base + path, {
        method,
        headers: body !== undefined ? { 'content-type': 'application/json' } : {},
        body: body !== undefined ? JSON.stringify(body) : undefined,
      })
      const text = await res.text()
      return {
        status: res.status,
        contentType: res.headers.get('content-type'),
        body: text ? JSON.parse(text) : null,
      }
    },
    async raw(method, path, rawBody, contentType = 'application/json') {
      const res = await fetch(base + path, {
        method,
        headers: { 'content-type': contentType },
        body: rawBody,
      })
      const text = await res.text()
      return { status: res.status, body: text ? JSON.parse(text) : null }
    },
  }
}

export const uuid = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`

export const task = (n, overrides = {}) => ({
  id: uuid(n),
  title: `Task ${n}`,
  ...overrides,
})
