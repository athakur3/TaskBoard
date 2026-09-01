import Foundation
import Testing
@testable import TaskBoard

/// Pins the HTTP status → APIClientError mapping — the retryable-vs-terminal
/// vs-conflict distinction the sync engine's whole control flow switches on.
/// Pure function tests: no instance, no network, no mocks.
struct APIClientErrorMappingTests {

    private func envelope(code: String, message: String = "msg", current: Bool) -> Data {
        let currentJSON = current ? """
        , "current": {"id":"t1","title":"Server","description":"d","status":"todo","orderKey":"V","version":5,"deleted":false,"createdAt":"2026-08-31T09:12:45.123Z","updatedAt":"2026-08-31T09:12:45.123Z"}
        """ : ""
        return Data("""
        {"error": {"code": "\(code)", "message": "\(message)"\(currentJSON)}}
        """.utf8)
    }

    @Test func testVersionConflictCarriesCurrentRow() {
        let error = URLSessionAPIClient.mapError(status: 409, data: envelope(code: "VERSION_CONFLICT", current: true))
        guard case .versionConflict(let current) = error else { Issue.record("expected versionConflict, got \(error)"); return }
        #expect(current.version == 5)
        #expect(current.title == "Server")
    }

    @Test func testVersionConflictWithoutCurrentRowIsMalformed() {
        let error = URLSessionAPIClient.mapError(status: 409, data: envelope(code: "VERSION_CONFLICT", current: false))
        guard case .malformedResponse = error else { Issue.record("expected malformedResponse, got \(error)"); return }
    }

    @Test func testTaskDeletedCarriesTombstone() {
        let error = URLSessionAPIClient.mapError(status: 409, data: envelope(code: "TASK_DELETED", current: true))
        guard case .taskDeleted(let tombstone) = error else { Issue.record("expected taskDeleted, got \(error)"); return }
        #expect(tombstone.id == "t1")
    }

    @Test func testTaskDeletedWithoutCurrentRowIsMalformed() {
        let error = URLSessionAPIClient.mapError(status: 409, data: envelope(code: "TASK_DELETED", current: false))
        guard case .malformedResponse = error else { Issue.record("expected malformedResponse, got \(error)"); return }
    }

    @Test func test410MapsToCursorReset() {
        #expect(URLSessionAPIClient.mapError(status: 410, data: Data()) == .cursorReset)
    }

    @Test func test404MapsToTaskNotFound() {
        #expect(URLSessionAPIClient.mapError(status: 404, data: Data()) == .taskNotFound)
    }

    @Test func test400MapsToValidationWithServerMessage() {
        let error = URLSessionAPIClient.mapError(status: 400, data: envelope(code: "VALIDATION", message: "title too long", current: false))
        #expect(error == .validation("title too long"))
    }

    @Test func test5xxMapsToRetryable() {
        let error = URLSessionAPIClient.mapError(status: 503, data: envelope(code: "INJECTED_FAILURE", message: "chaos", current: false))
        #expect(error == .retryable("chaos"))
    }

    @Test func testUnknownStatusWithUndecodableBodyFallsBackToRetryable() {
        #expect(URLSessionAPIClient.mapError(status: 418, data: Data("not json".utf8)) == .retryable("HTTP 418"))
    }

    @Test func testDecodeOnGarbageThrowsMalformedResponse() {
        do {
            _ = try URLSessionAPIClient.decode(TaskItem.self, from: Data("{".utf8))
            Issue.record("decode of garbage must throw")
        } catch APIClientError.malformedResponse {
            // expected
        } catch {
            Issue.record("expected malformedResponse, got \(error)")
        }
    }
}
