// DB row -> canonical wire Task (BACKEND_DESIGN.md §5). server_seq is not
// exposed; clients only need the top-level latestSeq cursor.
export function toWire(row) {
  return {
    id: row.id,
    title: row.title,
    description: row.description,
    status: row.status,
    orderKey: row.order_key,
    version: row.version,
    deleted: row.deleted === 1,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }
}
