import Foundation
import Testing
@testable import TaskBoard

/// Pins the client to the server's exact wire shapes (design §5): camelCase,
/// "description" ↔ details mapping, status tokens, 3-digit-millis timestamps.
struct WireDecodingTests {
    @Test func testDecodesCanonicalTaskPayload() throws {
        let json = """
        { "id": "7f7a0e2e-1d2b-4b7e-9c3a-2f8e6d4c1a90", "title": "Buy milk",
          "description": "2% if they have it", "status": "inProgress", "orderKey": "hV",
          "version": 3, "deleted": false,
          "createdAt": "2026-08-30T18:04:02.911Z", "updatedAt": "2026-08-31T10:02:11.456Z" }
        """
        let task = try JSONDecoder().decode(TaskItem.self, from: Data(json.utf8))
        #expect(task.details == "2% if they have it")
        #expect(task.status == .inProgress)
        #expect(task.version == 3)
        #expect(WireDate.parse(task.createdAt) != nil, "fractional-second timestamps must parse")
    }

    @Test func testDecodesWrappedCollectionAndTombstone() throws {
        let json = """
        { "boardEpoch": "e", "latestSeq": 4, "tasks": [
          { "id": "00000000-0000-4000-8000-000000000001", "title": "Gone", "description": "",
            "status": "done", "orderKey": "8", "version": 2, "deleted": true,
            "createdAt": "2026-08-31T09:00:00.000Z", "updatedAt": "2026-08-31T09:30:00.000Z" } ] }
        """
        let response = try JSONDecoder().decode(TasksResponse.self, from: Data(json.utf8))
        #expect(response.latestSeq == 4)
        #expect(response.tasks[0].deleted)
    }

    @Test func testEncodesUpdateBodyWithWireFieldNames() throws {
        let body = UpdateTaskBody(baseVersion: 2, mutationId: "m", title: nil, details: "new", status: .done, orderKey: nil)
        let dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any]
        #expect(dict["description"] as? String == "new")
        #expect(dict["status"] as? String == "done")
        #expect(dict["baseVersion"] as? Int == 2)
        #expect(dict["title"] == nil, "unset fields must be absent, not null")
        #expect(dict["details"] == nil, "the internal name must never leak onto the wire")
    }

    @Test func testErrorEnvelopeWithCurrentDecodes() throws {
        let json = """
        { "error": { "code": "VERSION_CONFLICT", "message": "stale",
          "current": { "id": "00000000-0000-4000-8000-000000000001", "title": "T", "description": "",
            "status": "todo", "orderKey": "V", "version": 5, "deleted": false,
            "createdAt": "2026-08-31T09:00:00.000Z", "updatedAt": "2026-08-31T09:00:00.000Z" } } }
        """
        let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(json.utf8))
        #expect(envelope.error.code == "VERSION_CONFLICT")
        #expect(envelope.error.current?.version == 5)
    }
}
