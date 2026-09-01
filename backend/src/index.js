import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createDb } from './db.js'
import { createApp } from './app.js'

const here = path.dirname(fileURLToPath(import.meta.url))
const dbFile = process.env.DB_FILE || path.join(here, '..', 'taskboard.db')
const port = Number(process.env.PORT || 4000)

const db = createDb(dbFile)
const { app, store } = createApp(db, { log: true }) // watch the app's sync rhythm live
store.seedIfEmpty()

const server = app.listen(port, () => {
  const m = store.meta()
  console.log(`Task Board server listening on http://localhost:${port}`)
  console.log(`  db: ${dbFile}`)
  console.log(`  boardEpoch: ${m.boardEpoch}  latestSeq: ${m.lastSeq}`)
})

function shutdown() {
  server.close(() => {
    db.close()
    process.exit(0)
  })
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
