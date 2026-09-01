import Foundation

/// Outcome taxonomy the sync engine acts on (design §8: terminal vs transient
/// vs conflict is the load-bearing distinction).
enum APIClientError: Error, Equatable {
    /// Network unreachable, timeout, 5xx, injected 503 — retry later with the
    /// SAME mutationId; the server's idempotency machinery makes that safe.
    case retryable(String)
    /// 400 — the op is dropped and surfaced; retrying identical bytes cannot succeed.
    case validation(String)
    /// 404 — the id never existed (distinct from TASK_DELETED by contract).
    case taskNotFound
    /// 409 VERSION_CONFLICT — carries the current server row for rebasing.
    case versionConflict(TaskItem)
    /// 409 TASK_DELETED — delete wins; carries the tombstone.
    case taskDeleted(TaskItem)
    /// 410 CURSOR_RESET — cursor is ahead of the server; full resync required.
    case cursorReset
    /// The response didn't match the contract: non-HTTP, an undecodable body,
    /// or a 409 missing its `current` row. Retried like `retryable`.
    case malformedResponse(String)
}

protocol TaskAPI: Sendable {
    func fetchTasks(since: Int?) async throws -> TasksResponse
    func getTask(id: String) async throws -> TaskItem
    func create(_ body: CreateTaskBody) async throws -> TaskItem
    func update(id: String, _ body: UpdateTaskBody) async throws -> TaskItem
    func delete(id: String) async throws
}

enum HTTPMethod: String {
    case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE"
}

/// One value per server route — the only place wire paths are spelled.
struct Endpoint {
    var method: HTTPMethod
    var path: String
    var body: (any Encodable)? = nil

    static func fetchTasks(since: Int?) -> Endpoint {
        Endpoint(method: .get, path: since.map { "/tasks?since=\($0)" } ?? "/tasks")
    }
    static func getTask(id: String) -> Endpoint {
        Endpoint(method: .get, path: "/tasks/\(id)")
    }
    static func createTask(_ body: CreateTaskBody) -> Endpoint {
        Endpoint(method: .post, path: "/tasks", body: body)
    }
    static func updateTask(id: String, _ body: UpdateTaskBody) -> Endpoint {
        Endpoint(method: .patch, path: "/tasks/\(id)", body: body)
    }
    static func deleteTask(id: String) -> Endpoint {
        Endpoint(method: .delete, path: "/tasks/\(id)")
    }
}

/// The board's offline toggle cuts requests off here, before the socket, so
/// airplane-mode behavior is demonstrable without touching the network stack.
final class URLSessionAPIClient: TaskAPI, @unchecked Sendable {
    private let config: NetworkConfig
    private let session: URLSession

    init(config: NetworkConfig) {
        self.config = config
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func fetchTasks(since: Int?) async throws -> TasksResponse {
        try await request(.fetchTasks(since: since))
    }

    func getTask(id: String) async throws -> TaskItem {
        try await request(.getTask(id: id))
    }

    func create(_ body: CreateTaskBody) async throws -> TaskItem {
        try await request(.createTask(body))
    }

    /// The server echoes a `replayed` flag when its ledger absorbed a retry of
    /// an already-applied mutation; it is intentionally ignored — a replay
    /// returns the same row, so `completeOp` behaves identically either way.
    func update(id: String, _ body: UpdateTaskBody) async throws -> TaskItem {
        try await request(.updateTask(id: id, body))
    }

    func delete(id: String) async throws {
        _ = try await perform(.deleteTask(id: id))
    }

    // MARK: - Generic request path

    /// Every response-bearing endpoint flows through here: an `Endpoint` in,
    /// the JSON-decoded `Decodable` model out.
    func request<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let (data, _) = try await perform(endpoint)
        return try Self.decode(T.self, from: data)
    }

    private func perform(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        if config.simulateOffline {
            throw APIClientError.retryable("Simulated offline (debug setting)")
        }
        guard let url = URL(string: config.baseURL + endpoint.path) else {
            throw APIClientError.validation("Invalid server URL: \(config.baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        if let body = endpoint.body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIClientError.retryable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.malformedResponse("Non-HTTP response")
        }
        if (200..<300).contains(http.statusCode) {
            return (data, http)
        }
        throw Self.mapError(status: http.statusCode, data: data)
    }

    /// HTTP status + server error envelope → the taxonomy above. Static so the
    /// mapping is unit-testable without an instance or a network.
    static func mapError(status: Int, data: Data) -> APIClientError {
        let envelope = try? decode(APIErrorEnvelope.self, from: data)
        let code = envelope?.error.code ?? ""
        let message = envelope?.error.message ?? "HTTP \(status)"
        switch (status, code) {
        case (409, "VERSION_CONFLICT"):
            if let current = envelope?.error.current { return .versionConflict(current) }
            return .malformedResponse("VERSION_CONFLICT without current row")
        case (409, "TASK_DELETED"):
            if let current = envelope?.error.current { return .taskDeleted(current) }
            return .malformedResponse("TASK_DELETED without current row")
        case (410, _): return .cursorReset
        case (404, _): return .taskNotFound
        case (400, _): return .validation(message)
        case (500..<600, _): return .retryable(message)
        default: return .retryable(message)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIClientError.malformedResponse("Undecodable response: \(error)")
        }
    }
}
