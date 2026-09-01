import Foundation

/// Fractional ordering keys over base-62, a direct port of the server's
/// algorithm (backend/src/orderkey.js; design §10). Bytewise comparison order is
/// identical in SQLite BINARY collation, JSON, and Swift String < for ASCII.
enum OrderKey {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let minDigit: Character = "0"

    static func isValid(_ key: String) -> Bool {
        guard !key.isEmpty, key.count <= 128, key.last != minDigit else { return false }
        return key.allSatisfy { $0.isASCII && ($0.isNumber || ($0.isLetter && $0.asciiValue != nil)) }
    }

    /// Shortest string strictly between `a` and `b`. `a` may be "" (lower
    /// bound); `b` may be nil (upper bound). NEVER traps: replication can
    /// legitimately produce equal neighbor keys (design §10 — concurrent
    /// same-gap inserts, tie-broken by id), so degenerate bounds fall back to
    /// a key after the lower bound instead of crashing mid-drag.
    static func midpoint(_ a: String, _ b: String?) -> String {
        var lower = a
        while lower.last == minDigit { lower.removeLast() }
        var upper: String? = nil
        if var u = b {
            while u.last == minDigit { u.removeLast() }
            if !u.isEmpty { upper = u }
        }
        if let u = upper, lower >= u {
            // Equal or inverted neighbors: any legal key converges via the
            // (orderKey, id) tie-break — append after the lower bound.
            return core(lower, nil)
        }
        return core(lower, upper)
    }

    private static func core(_ a: String, _ b: String?) -> String {
        let aChars = Array(a)
        if let b {
            let bChars = Array(b)
            var n = 0
            while n < bChars.count && (n < aChars.count ? aChars[n] : minDigit) == bChars[n] { n += 1 }
            if n > 0 {
                return String(bChars.prefix(n)) + core(String(aChars.dropFirst(n)), String(bChars.dropFirst(n)))
            }
        }
        let digitA = aChars.isEmpty ? 0 : (digits.firstIndex(of: aChars[0]) ?? 0)
        let digitB: Int
        if let b, let first = b.first {
            digitB = digits.firstIndex(of: first) ?? digits.count
        } else {
            digitB = digits.count
        }
        if digitB - digitA > 1 {
            let mid = Int((0.5 * Double(digitA + digitB)).rounded())
            return String(digits[mid])
        }
        if let b, b.count > 1 {
            return String(b.first!)
        }
        return String(digits[digitA]) + core(String(aChars.dropFirst()), nil)
    }

    /// A key sorting after the current column maximum ("V" for an empty column).
    static func after(_ maxKey: String?) -> String {
        midpoint(maxKey ?? "", nil)
    }

    /// A key strictly between two neighbors (nil-bounded at either end).
    static func between(_ lower: String?, _ upper: String?) -> String {
        midpoint(lower ?? "", upper)
    }
}
