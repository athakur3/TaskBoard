// Wire timestamps are RFC 3339 UTC with exactly three fractional digits and a
// literal Z (BACKEND_DESIGN.md §5). toISOString() produces exactly that shape.
export function nowIso() {
  return new Date().toISOString()
}

const ISO_SHAPE = /^(\d{4})-(\d{2})-(\d{2})[Tt ]\d{2}:\d{2}/

// Accept any valid ISO-8601 instant, re-serialize to the canonical shape.
// Returns null when unparseable. V8's Date.parse rejects out-of-range time
// components but silently rolls day-of-month overflow (Feb 30 -> Mar 2), so
// the calendar date is validated explicitly before parsing.
export function canonicalTimestamp(value) {
  if (typeof value !== 'string') return null
  const m = ISO_SHAPE.exec(value)
  if (!m) return null
  const year = Number(m[1])
  const month = Number(m[2])
  const day = Number(m[3])
  if (month < 1 || month > 12) return null
  const daysInMonth = new Date(Date.UTC(year, month, 0)).getUTCDate()
  if (day < 1 || day > daysInMonth) return null
  const ms = Date.parse(value)
  if (Number.isNaN(ms)) return null
  return new Date(ms).toISOString()
}
