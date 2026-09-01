import Foundation

/// Wire status tokens are identical in the server DB, JSON, and here — no
/// mapping layer exists to have bugs (BACKEND_DESIGN.md §5).
enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case todo
    case inProgress
    case done

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .todo: return "To Do"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        }
    }

    /// Workflow rule, mirrored in the backend contract (400 INVALID_TRANSITION):
    /// one column at a time, either direction — todo ↔ inProgress ↔ done.
    /// `forward` walks toward Done, `backward` toward To Do.
    var forward: TaskStatus? {
        switch self {
        case .todo: return .inProgress
        case .inProgress: return .done
        case .done: return nil
        }
    }

    var backward: TaskStatus? {
        switch self {
        case .todo: return nil
        case .inProgress: return .todo
        case .done: return .inProgress
        }
    }

    var adjacentColumns: [TaskStatus] { [backward, forward].compactMap { $0 } }

    /// Staying put is always allowed (a reorder is not a transition).
    func canMove(to target: TaskStatus) -> Bool {
        target == self || adjacentColumns.contains(target)
    }
}

/// The canonical Task payload (BACKEND_DESIGN.md §5) — one schema everywhere:
/// fetches, mutation responses, delta rows, and 409 envelopes.
struct TaskItem: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var details: String
    var status: TaskStatus
    var orderKey: String
    var version: Int
    var deleted: Bool
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, status, orderKey, version, deleted, createdAt, updatedAt
        case details = "description"
    }
}

/// Per-task sync state surfaced in the UI (assignment requirement: the user
/// must understand whether their changes have been synchronized).
enum TaskSyncBadge: Equatable {
    case synced
    case pending          // queued local ops exist
    case failed(String)   // terminal error or transient outage
    case conflict         // same-field conflict awaiting user resolution
}

/// A task as the UI consumes it: value type + badge, never a managed object.
struct BoardTask: Equatable, Identifiable {
    var item: TaskItem
    var badge: TaskSyncBadge
    var id: String { item.id }
}

#if DEBUG
extension TaskItem {
    /// Preview fixture.
    static func sample(title: String = "Design offline badges",
                       details: String = "Pending / synced / failed states per task.",
                       status: TaskStatus = .todo,
                       version: Int = 3) -> TaskItem {
        TaskItem(id: UUID().uuidString.lowercased(), title: title, details: details,
                 status: status, orderKey: "V", version: version, deleted: false,
                 createdAt: "2026-08-31T09:12:45.123Z", updatedAt: "2026-09-01T18:04:00.000Z")
    }
}
#endif
