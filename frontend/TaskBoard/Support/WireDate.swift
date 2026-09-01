import Foundation

/// The server emits RFC 3339 UTC with exactly three fractional digits
/// (2026-08-31T09:12:45.123Z). Swift's JSONDecoder `.iso8601` strategy fails on
/// fractional seconds, so timestamps stay Strings end to end and are parsed
/// only for display (no sync decision ever reads a timestamp — design §5).
enum WireDate {
    // ISO8601DateFormatter is documented thread-safe (unlike DateFormatter),
    // so sharing one instance across isolation domains is sound.
    nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func now() -> String {
        formatter.string(from: Date())
    }

    static func parse(_ value: String) -> Date? {
        formatter.date(from: value)
    }

    static func displayString(_ value: String) -> String {
        guard let date = parse(value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
