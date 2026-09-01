// Fractional ordering keys over base-62 (BACKEND_DESIGN.md §10).
// Bytewise comparison order: 0-9 < A-Z < a-z, identical in SQLite BINARY
// collation, JSON strings, and Swift String < for pure ASCII.
export const DIGITS = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
const MIN_DIGIT = '0'

export const ORDER_KEY_RE = /^[0-9A-Za-z]{1,128}$/

// Generated keys never end in the reserved minimum digit, so a strictly-between
// key always exists (the "K"/"K0" prefix-adjacency edge case).
export function isValidOrderKey(key) {
  return typeof key === 'string' && ORDER_KEY_RE.test(key) && !key.endsWith(MIN_DIGIT)
}

// Shortest string strictly between a and b. a may be '' (lower bound of the
// space); b may be null (upper bound). Inputs must not end in '0'.
export function midpoint(a, b) {
  if (b !== null && a >= b) throw new Error(`midpoint: "${a}" >= "${b}"`)
  if (a.endsWith(MIN_DIGIT) || (b !== null && b.endsWith(MIN_DIGIT))) {
    throw new Error('midpoint: inputs must not end in the minimum digit')
  }
  if (b !== null) {
    // Strip the longest common prefix, padding a with the min digit as we go.
    let n = 0
    while ((a.charAt(n) || MIN_DIGIT) === b.charAt(n)) n++
    if (n > 0) return b.slice(0, n) + midpoint(a.slice(n), b.slice(n))
  }
  const digitA = a ? DIGITS.indexOf(a.charAt(0)) : 0
  const digitB = b !== null ? DIGITS.indexOf(b.charAt(0)) : DIGITS.length
  if (digitB - digitA > 1) {
    return DIGITS.charAt(Math.round(0.5 * (digitA + digitB)))
  }
  // First digits are consecutive.
  if (b !== null && b.length > 1) return b.slice(0, 1)
  return DIGITS.charAt(digitA) + midpoint(a.slice(1), null)
}

// Key sorting after the current maximum in a column ('' / null when empty).
// First key in an empty column is 'V'.
export function keyAfter(maxKey) {
  return midpoint(maxKey || '', null)
}
