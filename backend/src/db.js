import Database from 'better-sqlite3'
import { randomUUID } from 'node:crypto'

// DDL from BACKEND_DESIGN.md §4. Idempotent: safe to run at every boot.
// Tests run the identical DDL against ':memory:'.
const DDL = `
CREATE TABLE IF NOT EXISTS sync_state (
  id          INTEGER PRIMARY KEY CHECK (id = 1),
  last_seq    INTEGER NOT NULL DEFAULT 0,
  board_epoch TEXT    NOT NULL
);

CREATE TABLE IF NOT EXISTS tasks (
  id          TEXT    PRIMARY KEY,
  title       TEXT    NOT NULL CHECK (length(title) BETWEEN 1 AND 500),
  description TEXT    NOT NULL DEFAULT ''  CHECK (length(description) <= 4000),
  status      TEXT    NOT NULL CHECK (status IN ('todo','inProgress','done')),
  order_key   TEXT    NOT NULL CHECK (length(order_key) BETWEEN 1 AND 128),
  version     INTEGER NOT NULL DEFAULT 1,
  deleted     INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0,1)),
  created_at  TEXT    NOT NULL,
  updated_at  TEXT    NOT NULL,
  server_seq  INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_seq   ON tasks (server_seq);
CREATE INDEX        IF NOT EXISTS idx_tasks_board ON tasks (status, order_key, id) WHERE deleted = 0;

CREATE TABLE IF NOT EXISTS applied_mutations (
  mutation_id TEXT PRIMARY KEY,
  task_id     TEXT NOT NULL,
  applied_at  TEXT NOT NULL
);
`

export function createDb(filename) {
  const db = new Database(filename)
  db.pragma('journal_mode = WAL')
  db.pragma('busy_timeout = 5000')
  db.exec(DDL)
  const row = db.prepare('SELECT id FROM sync_state WHERE id = 1').get()
  if (!row) {
    db.prepare('INSERT INTO sync_state (id, last_seq, board_epoch) VALUES (1, 0, ?)').run(randomUUID())
  }
  return db
}
