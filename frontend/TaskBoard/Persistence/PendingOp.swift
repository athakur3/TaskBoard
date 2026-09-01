import Foundation

enum OpKind: String, Codable {
    case create, update, delete
}

/// Absolute-state payload (design §8: mutations are absolute, never relative,
/// so reapplication is naturally idempotent). Only the fields being set are
/// non-nil.
struct OpPayload: Codable, Equatable {
    var title: String?
    var details: String?
    var status: TaskStatus?
    var orderKey: String?
    var createdAt: String?

    var isEmpty: Bool {
        title == nil && details == nil && status == nil && orderKey == nil
    }

    /// Field names for conflict detection, with status+orderKey treated as the
    /// atomic position group (design §9 rows 7–8).
    var changedFields: Set<String> {
        var fields = Set<String>()
        if title != nil { fields.insert("title") }
        if details != nil { fields.insert("details") }
        if status != nil || orderKey != nil { fields.insert("position") }
        return fields
    }

    mutating func merge(_ newer: OpPayload) {
        if let v = newer.title { title = v }
        if let v = newer.details { details = v }
        if let v = newer.status { status = v }
        if let v = newer.orderKey { orderKey = v }
        if let v = newer.createdAt { createdAt = v }
    }

    static func encode(_ payload: OpPayload) -> String {
        String(data: try! JSONEncoder().encode(payload), encoding: .utf8)!
    }

    static func decode(_ json: String) -> OpPayload {
        (try? JSONDecoder().decode(OpPayload.self, from: Data(json.utf8))) ?? OpPayload()
    }
}

/// Value-type view of a queue entry, handed to the sync engine.
struct PendingOp: Equatable {
    var opId: Int64
    var taskId: String
    var kind: OpKind
    var payload: OpPayload
    var mutationId: String
    var transmitted: Bool
    var rebaseCount: Int
}

/// Stored on a task while a same-field conflict awaits user resolution.
struct ConflictRecord: Codable, Equatable {
    var mine: OpPayload
    var theirs: TaskItem
    var fields: [String]

    static func encode(_ record: ConflictRecord) -> String {
        String(data: try! JSONEncoder().encode(record), encoding: .utf8)!
    }

    static func decode(_ json: String?) -> ConflictRecord? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(ConflictRecord.self, from: Data(json.utf8))
    }
}
