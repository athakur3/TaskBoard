import Foundation

/// GET /tasks response — collections are always wrapped in an object.
struct TasksResponse: Codable {
    var boardEpoch: String
    var latestSeq: Int
    var tasks: [TaskItem]
}

/// Error envelope (BACKEND_DESIGN.md §7). `current` rides on the two 409s.
struct APIErrorEnvelope: Codable {
    struct Payload: Codable {
        var code: String
        var message: String
        var current: TaskItem?
    }
    var error: Payload
}

struct CreateTaskBody: Codable, Equatable {
    var id: String
    var title: String
    var status: TaskStatus
    var orderKey: String?
    var createdAt: String
    var details: String

    enum CodingKeys: String, CodingKey {
        case id, title, status, orderKey, createdAt
        case details = "description"
    }
}

/// PATCH body: any subset of the four updatable fields plus the two mandatory
/// sync fields. `baseVersion` is bound at SEND time (BACKEND_DESIGN.md §8).
struct UpdateTaskBody: Codable, Equatable {
    var baseVersion: Int
    var mutationId: String
    var title: String?
    var details: String?
    var status: TaskStatus?
    var orderKey: String?

    enum CodingKeys: String, CodingKey {
        case baseVersion, mutationId, title, status, orderKey
        case details = "description"
    }
}
