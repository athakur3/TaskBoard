import Foundation
@testable import TaskBoard

/// Scriptable fake server. Each expectation consumes one request; `fallback`
/// handles the rest. Records every request for assertions.
final class MockTaskAPI: TaskAPI, @unchecked Sendable {
    enum Request: Equatable {
        case fetch(since: Int?)
        case get(id: String)
        case create(CreateTaskBody)
        case update(id: String, UpdateTaskBody)
        case delete(id: String)
    }

    private let lock = NSLock()
    private(set) var requests: [Request] = []
    var scripted: [(Request) -> Result<Any, APIClientError>?] = []
    var fallback: (Request) -> Result<Any, APIClientError> = { _ in .failure(.retryable("unscripted")) }

    func record(_ request: Request) throws -> Any {
        lock.lock()
        requests.append(request)
        var handler: Result<Any, APIClientError>?
        var consumedIndex: Int?
        for (i, script) in scripted.enumerated() {
            if let result = script(request) {
                handler = result
                consumedIndex = i
                break
            }
        }
        if let consumedIndex { scripted.remove(at: consumedIndex) }
        lock.unlock()
        let result = handler ?? fallback(request)
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    func fetchTasks(since: Int?) async throws -> TasksResponse {
        try record(.fetch(since: since)) as! TasksResponse
    }
    func getTask(id: String) async throws -> TaskItem {
        try record(.get(id: id)) as! TaskItem
    }
    func create(_ body: CreateTaskBody) async throws -> TaskItem {
        try record(.create(body)) as! TaskItem
    }
    func update(id: String, _ body: UpdateTaskBody) async throws -> TaskItem {
        try record(.update(id: id, body)) as! TaskItem
    }
    func delete(id: String) async throws {
        _ = try record(.delete(id: id))
    }
}

// MARK: - Shared fixtures

extension TaskItem {
    static func fixture(
        id: String = "00000000-0000-4000-8000-000000000001",
        title: String = "Fixture",
        details: String = "",
        status: TaskStatus = .todo,
        orderKey: String = "V",
        version: Int = 1,
        deleted: Bool = false
    ) -> TaskItem {
        TaskItem(id: id, title: title, details: details, status: status, orderKey: orderKey,
                 version: version, deleted: deleted,
                 createdAt: "2026-08-31T09:00:00.000Z", updatedAt: "2026-08-31T09:00:00.000Z")
    }

    /// The server's echo of an applied mutation.
    func applying(_ body: UpdateTaskBody) -> TaskItem {
        var next = self
        if let v = body.title { next.title = v }
        if let v = body.details { next.details = v }
        if let v = body.status { next.status = v }
        if let v = body.orderKey { next.orderKey = v }
        next.version = body.baseVersion + 1
        next.updatedAt = "2026-08-31T10:00:00.000Z"
        return next
    }
}

@MainActor
func makeHarness() -> (store: LocalStore, api: MockTaskAPI, engine: SyncEngine, status: SyncStatusCenter) {
    let store = LocalStore(inMemory: true)
    let api = MockTaskAPI()
    let status = SyncStatusCenter()
    let engine = SyncEngine(store: store, api: api, status: status)
    return (store, api, engine, status)
}
