import Foundation
import Testing
@testable import TaskBoard

/// Queue semantics (design §8, the mandatory client rules) against real SQLite
/// (Core Data on /dev/null).
struct LocalStoreTests {
    // Fresh per test: Swift Testing instantiates the suite for each @Test.
    let store = LocalStore(inMemory: true)

    @Test func testCreateEnqueuesOneOpAndLandsAtColumnEnd() async throws {
        let a = try await store.createTask(title: "A", details: "", status: .todo)
        let b = try await store.createTask(title: "B", details: "", status: .todo)
        #expect(a.orderKey == "V")
        #expect(b.orderKey > a.orderKey)
        let ops = try await store.queueSnapshot()
        #expect(ops.map(\.kind) == [.create, .create])
        #expect(ops[0].opId == 1)
        #expect(ops[1].opId == 2, "op ids are a monotonic local counter")
    }

    @Test func testEditsCoalesceIntoUntransmittedCreate() async throws {
        let task = try await store.createTask(title: "Draft", details: "", status: .todo)
        try await store.updateTask(id: task.id, OpPayload(title: "Final", details: "polished"))
        let ops = try await store.queueSnapshot()
        #expect(ops.count == 1, "edit merged into the untransmitted create")
        #expect(ops[0].kind == .create)
        #expect(ops[0].payload.title == "Final")
        #expect(ops[0].payload.details == "polished")
    }

    @Test func testSuccessiveMovesQueueOneWorkflowStepPerOp() async throws {
        // Synced task (no create op to absorb into): offline todo -> inProgress
        // -> done must NOT collapse into one todo -> done op — the server
        // rejects that skip (INVALID_TRANSITION). One column move per op; the
        // FIFO queue replays them as two legal steps.
        _ = try await store.applyPull(rows: [TaskItem.fixture()], cursor: 1, boardEpoch: "e1")
        let id = TaskItem.fixture().id
        try await store.moveTask(id: id, to: .inProgress)
        try await store.moveTask(id: id, to: .done)
        let ops = try await store.queueSnapshot()
        #expect(ops.map(\.kind) == [.update, .update], "a different status step opens a new op")
        #expect(ops[0].payload.status == .inProgress)
        #expect(ops[1].payload.status == .done)
        let board = try await store.board()
        #expect(board[0].item.status == .done, "the board still shows the latest move immediately")
    }

    @Test func testTextEditsAndSameColumnMovesStillCoalesce() async throws {
        // The workflow split is surgical: only a DIFFERENT status step refuses
        // to merge. Text edits and same-column positions coalesce as ever (§8).
        _ = try await store.applyPull(rows: [TaskItem.fixture()], cursor: 1, boardEpoch: "e1")
        let id = TaskItem.fixture().id
        try await store.moveTask(id: id, to: .inProgress)
        try await store.updateTask(id: id, OpPayload(title: "Renamed"))
        try await store.moveTask(id: id, to: .inProgress) // reorder within the column
        let ops = try await store.queueSnapshot()
        #expect(ops.count == 1)
        #expect(ops[0].payload.status == .inProgress)
        #expect(ops[0].payload.title == "Renamed")
    }

    @Test func testMoveBehindUntransmittedCreateQueuesItsOwnStep() async throws {
        // Even a not-yet-synced task moves by queued steps: the create keeps
        // its birth column and the move becomes an update behind it, so the
        // wire sees create(todo) then a legal todo -> inProgress transition.
        let task = try await store.createTask(title: "Draft", details: "", status: .todo)
        try await store.moveTask(id: task.id, to: .inProgress)
        let ops = try await store.queueSnapshot()
        #expect(ops.map(\.kind) == [.create, .update])
        #expect(ops[0].payload.status == .todo)
        #expect(ops[1].payload.status == .inProgress)
        let board = try await store.board()
        #expect(board[0].item.status == .inProgress, "the board shows the move immediately")
    }

    @Test func testTransmittedOpIsFrozen() async throws {
        let task = try await store.createTask(title: "Draft", details: "", status: .todo)
        var ops = try await store.queueSnapshot()
        _ = try await store.markTransmitted(opId: ops[0].opId)
        try await store.updateTask(id: task.id, OpPayload(title: "Later edit"))
        ops = try await store.queueSnapshot()
        #expect(ops.count == 2, "once on the wire, an op is frozen; edits enqueue behind")
        #expect(ops[0].payload.title == "Draft")
        #expect(ops[1].kind == .update)
        #expect(ops[1].payload.title == "Later edit")
    }

    @Test func testCreateThenDeleteCancelsLocally() async throws {
        let task = try await store.createTask(title: "Oops", details: "", status: .todo)
        _ = try await store.deleteTask(id: task.id)
        let ops = try await store.queueSnapshot()
        #expect(ops.isEmpty, "untransmitted create + delete never hits the wire")
        let board = try await store.board()
        #expect(board.isEmpty)
    }

    @Test func testDeleteAfterTransmitQueuesDeleteBehindFrozenCreate() async throws {
        let task = try await store.createTask(title: "Sent", details: "", status: .todo)
        var ops = try await store.queueSnapshot()
        _ = try await store.markTransmitted(opId: ops[0].opId)
        try await store.updateTask(id: task.id, OpPayload(title: "moot edit"))
        _ = try await store.deleteTask(id: task.id)
        ops = try await store.queueSnapshot()
        #expect(ops.map(\.kind) == [.create, .delete], "untransmitted edit dropped as moot; delete behind frozen create")
        let board = try await store.board()
        #expect(board.isEmpty, "deleted task hidden from the board immediately")
    }

    @Test func testHeldTasksAreNotTransmitted() async throws {
        let task = try await store.createTask(title: "X", details: "", status: .todo)
        let ops = try await store.queueSnapshot()
        try await store.failOpTerminal(opId: ops[0].opId, message: "bad")
        try await store.updateTask(id: task.id, OpPayload(title: "held edit"))
        let heldOps = try await store.queueSnapshot()
        let ctx = try await store.markTransmitted(opId: heldOps[0].opId)
        #expect(ctx?.held == true)
        #expect(ctx?.op.transmitted == false, "held ops are not marked transmitted")
        try await store.clearFailure(taskId: task.id)
        let ctx2 = try await store.markTransmitted(opId: heldOps[0].opId)
        #expect(ctx2?.held == false)
    }

    @Test func testApplyPullUpsertsGuardedByVersionAndPersistsCursorAtomically() async throws {
        let row = TaskItem.fixture(title: "Server truth", version: 3)
        _ = try await store.applyPull(rows: [row], cursor: 7, boardEpoch: "e1")
        var meta = try await store.syncMeta()
        #expect(meta.cursor == 7)
        #expect(meta.boardEpoch == "e1")

        // Stale redelivery (crash before cursor persisted): must be a no-op.
        let stale = TaskItem.fixture(title: "Old", version: 2)
        _ = try await store.applyPull(rows: [stale], cursor: 7, boardEpoch: "e1")
        let board = try await store.board()
        #expect(board[0].item.title == "Server truth")

        let newer = TaskItem.fixture(title: "Newer", version: 4)
        _ = try await store.applyPull(rows: [newer], cursor: 9, boardEpoch: "e1")
        meta = try await store.syncMeta()
        #expect(meta.cursor == 9)
        let hoisted10 = try await store.board()
        #expect(hoisted10[0].item.title == "Newer")
    }

    @Test func testPullSkipsTasksWithPendingOps() async throws {
        _ = try await store.applyPull(rows: [TaskItem.fixture(title: "Synced", version: 1)], cursor: 1, boardEpoch: "e1")
        let id = TaskItem.fixture().id
        try await store.updateTask(id: id, OpPayload(title: "My typing"))
        let remote = TaskItem.fixture(title: "Remote edit", version: 2)
        _ = try await store.applyPull(rows: [remote], cursor: 2, boardEpoch: "e1")
        let board = try await store.board()
        #expect(board[0].item.title == "My typing", "sync must never revert in-flight local edits")
        #expect(board[0].badge == .pending)
    }

    @Test func testPullTombstoneDeletesLocally() async throws {
        _ = try await store.applyPull(rows: [TaskItem.fixture(version: 1)], cursor: 1, boardEpoch: "e1")
        let tombstone = TaskItem.fixture(version: 2, deleted: true)
        let outcome = try await store.applyPull(rows: [tombstone], cursor: 2, boardEpoch: "e1")
        #expect(outcome.deletedRemotely.count == 1)
        let board = try await store.board()
        #expect(board.isEmpty)
    }

    @Test func testEpochResetKeepsLocallyBornCreatesDropsTheRest() async throws {
        // A synced task with a pending edit, and a locally-born unsynced task.
        _ = try await store.applyPull(rows: [TaskItem.fixture(title: "Synced", version: 1)], cursor: 5, boardEpoch: "e1")
        try await store.updateTask(id: TaskItem.fixture().id, OpPayload(title: "doomed edit"))
        let local = try await store.createTask(title: "Born offline", details: "", status: .todo)

        let snapshot = [TaskItem.fixture(id: "00000000-0000-4000-8000-000000000009", title: "Fresh server task", version: 1)]
        let outcome = try await store.applyEpochReset(snapshot: snapshot, cursor: 1, boardEpoch: "e2")
        #expect(outcome.droppedOps == 1)
        #expect(outcome.keptLocalTasks == 1)

        let board = try await store.board()
        #expect(Set(board.map(\.item.title)) == ["Fresh server task", "Born offline"])
        let ops = try await store.queueSnapshot()
        #expect(ops.count == 1)
        #expect(ops[0].kind == .create)
        #expect(ops[0].taskId == local.id)
        let meta = try await store.syncMeta()
        #expect(meta.boardEpoch == "e2")
        #expect(meta.cursor == 1)
    }

    @Test func testBoardOrderIsStatusOrderKeyId() async throws {
        _ = try await store.applyPull(rows: [
            TaskItem.fixture(id: "00000000-0000-4000-8000-000000000002", title: "todo-G", status: .todo, orderKey: "G"),
            TaskItem.fixture(id: "00000000-0000-4000-8000-000000000003", title: "todo-8", status: .todo, orderKey: "8"),
            TaskItem.fixture(id: "00000000-0000-4000-8000-000000000004", title: "done-V", status: .done, orderKey: "V"),
        ], cursor: 3, boardEpoch: "e1")
        let board = try await store.board()
        let titles = board.filter { $0.item.status == .todo }.map(\.item.title)
        #expect(titles == ["todo-8", "todo-G"], "bytewise orderKey order within a column")
    }
}

extension LocalStoreTests {
    @Test func testDeletingConflictedOrFailedTaskDoesNotWedgeTheDelete() async throws {
        // Conflicted task: delete must clear the flag and transmit.
        _ = try await store.applyPull(rows: [TaskItem.fixture(version: 1)], cursor: 1, boardEpoch: "e1")
        let id = TaskItem.fixture().id
        try await store.updateTask(id: id, OpPayload(title: "Mine"))
        let op = (try await store.queueSnapshot())[0]
        try await store.recordConflict(opId: op.opId, mine: OpPayload(title: "Mine"), theirs: TaskItem.fixture(title: "Theirs", version: 2), fields: ["title"], positionLost: false)
        _ = try await store.deleteTask(id: id)
        let deleteOps = try await store.queueSnapshot()
        #expect(deleteOps.map(\.kind) == [.delete])
        let hoisted101 = try await store.markTransmitted(opId: deleteOps[0].opId)
        let ctx = try #require(hoisted101)
        #expect(!(ctx.held), "delete of a conflicted task must not be held — its badge is unreachable")

        // Failed-flagged task: same guarantee.
        let other = TaskItem.fixture(id: "00000000-0000-4000-8000-000000000055", title: "Failing", version: 1)
        _ = try await store.applyPull(rows: [other], cursor: 2, boardEpoch: "e1")
        try await store.updateTask(id: other.id, OpPayload(title: "Bad"))
        let failedOp = (try await store.queueSnapshot()).first { $0.taskId == other.id }!
        try await store.failOpTerminal(opId: failedOp.opId, message: "rejected")
        _ = try await store.deleteTask(id: other.id)
        let queued = (try await store.queueSnapshot()).first { $0.taskId == other.id }!
        let hoisted102 = try await store.markTransmitted(opId: queued.opId)
        let ctx2 = try #require(hoisted102)
        #expect(!(ctx2.held), "delete of a failed task must not be held")
    }

    @Test func testPullRefreshesOpenConflictAndTombstoneWinsOverIt() async throws {
        _ = try await store.applyPull(rows: [TaskItem.fixture(title: "Base", version: 1)], cursor: 1, boardEpoch: "e1")
        let id = TaskItem.fixture().id
        try await store.updateTask(id: id, OpPayload(title: "Mine"))
        let op = (try await store.queueSnapshot())[0]
        try await store.recordConflict(opId: op.opId, mine: OpPayload(title: "Mine"), theirs: TaskItem.fixture(title: "Theirs v2", version: 2), fields: ["title"], positionLost: false)

        // A newer server row arrives while the conflict is open: the stored
        // "theirs" must refresh, not rot.
        _ = try await store.applyPull(rows: [TaskItem.fixture(title: "Theirs v3", version: 3)], cursor: 3, boardEpoch: "e1")
        let hoisted103 = try await store.conflict(taskId: id)
        let record = try #require(hoisted103)
        #expect(record.theirs.version == 3)
        #expect(record.theirs.title == "Theirs v3")
        try await store.resolveConflictTakeTheirs(taskId: id)
        let board = try await store.board()
        #expect(board[0].item.title == "Theirs v3", "take-theirs adopts the CURRENT server row")
        #expect(board[0].item.version == 3)

        // Tombstone arriving over an open conflict: delete wins.
        try await store.updateTask(id: id, OpPayload(title: "Mine again"))
        let op2 = (try await store.queueSnapshot())[0]
        try await store.recordConflict(opId: op2.opId, mine: OpPayload(title: "Mine again"), theirs: TaskItem.fixture(title: "Theirs v4", version: 4), fields: ["title"], positionLost: false)
        let outcome = try await store.applyPull(rows: [TaskItem.fixture(version: 5, deleted: true)], cursor: 5, boardEpoch: "e1")
        #expect(outcome.deletedRemotely.count == 1)
        let empty = try await store.board()
        #expect(empty.isEmpty)
    }

    @Test func testKeepMinePreservesEditsMadeWhileConflictWasOpen() async throws {
        _ = try await store.applyPull(rows: [TaskItem.fixture(title: "Base", version: 1)], cursor: 1, boardEpoch: "e1")
        let id = TaskItem.fixture().id
        try await store.updateTask(id: id, OpPayload(title: "Old mine"))
        let op = (try await store.queueSnapshot())[0]
        try await store.recordConflict(opId: op.opId, mine: OpPayload(title: "Old mine"), theirs: TaskItem.fixture(title: "Theirs", version: 2), fields: ["title"], positionLost: false)

        // User keeps typing while the conflict sheet is pending.
        try await store.updateTask(id: id, OpPayload(title: "Even newer"))
        try await store.resolveConflictKeepMine(taskId: id)

        let board = try await store.board()
        #expect(board[0].item.title == "Even newer", "keep-mine must never resurrect the older conflicted text")
        let ops = try await store.queueSnapshot()
        #expect(ops.count == 1)
        #expect(ops[0].payload.title == "Even newer")
    }

    @Test func testTakeTheirsPreservesEditsMadeWhileConflictWasOpen() async throws {
        _ = try await store.applyPull(rows: [TaskItem.fixture(title: "Base", details: "base details", version: 1)], cursor: 1, boardEpoch: "e1")
        let id = TaskItem.fixture().id
        try await store.updateTask(id: id, OpPayload(title: "Old mine"))
        let op = (try await store.queueSnapshot())[0]
        try await store.recordConflict(opId: op.opId, mine: OpPayload(title: "Old mine"), theirs: TaskItem.fixture(title: "Theirs", details: "base details", version: 2), fields: ["title"], positionLost: false)

        // User keeps typing while the conflict sheet is pending, then adopts the server side.
        try await store.updateTask(id: id, OpPayload(details: "typed meanwhile"))
        try await store.resolveConflictTakeTheirs(taskId: id)

        let board = try await store.board()
        #expect(board[0].item.title == "Theirs", "take-theirs adopts the server's contested field")
        #expect(board[0].item.details == "typed meanwhile", "take-theirs must not wipe an edit queued while the sheet was open")
    }

    @Test func testRebasePreservesLaterQueuedEditsOnBoard() async throws {
        _ = try await store.applyPull(rows: [TaskItem.fixture(title: "Base", details: "base details", version: 1)], cursor: 1, boardEpoch: "e1")
        let id = TaskItem.fixture().id
        try await store.updateTask(id: id, OpPayload(title: "Mine"))
        let op1 = (try await store.queueSnapshot())[0]
        _ = try await store.markTransmitted(opId: op1.opId)
        // A second edit lands behind the frozen op.
        try await store.updateTask(id: id, OpPayload(details: "newer details"))
        // op1 draws a disjoint-field 409; the server changed only details upstream.
        try await store.rebaseOp(opId: op1.opId, newPayload: OpPayload(title: "Mine"), against: TaskItem.fixture(title: "Base", details: "server details", version: 2))

        let board = try await store.board()
        #expect(board[0].item.title == "Mine", "the rebased payload stays visible")
        #expect(board[0].item.details == "newer details", "a rebase must not revert edits queued behind the rebased op")
    }

    @Test func testClearFailureReenqueuesLostCreate() async throws {
        let created = try await store.createTask(title: "Rejected", details: "d", status: .todo)
        let op = (try await store.queueSnapshot())[0]
        try await store.failOpTerminal(opId: op.opId, message: "validation")
        try await store.clearFailure(taskId: created.id)
        let ops = try await store.queueSnapshot()
        #expect(ops.map(\.kind) == [.create], "retry on a locally-born task re-enqueues the create")
        #expect(ops[0].payload.title == "Rejected")
        let board = try await store.board()
        #expect(board[0].badge == .pending, "never badged synced for a task the server never accepted")
    }

    @Test func testValidationLimitsMirroredClientSide() async throws {
        let created = try await store.createTask(
            title: "  " + String(repeating: "x", count: 600),
            details: String(repeating: "y", count: 5000),
            status: .todo
        )
        #expect(created.title.count == 500, "title capped at 500 after trim (server §5)")
        #expect(created.details.count == 4000, "description capped at 4000")
        try await store.updateTask(id: created.id, OpPayload(title: String(repeating: "z", count: 700)))
        let ops = try await store.queueSnapshot()
        #expect(ops[0].payload.title?.count == 500, "queued payload can never draw a 400")
    }
}

extension LocalStoreTests {
    @Test func testPlaceTaskCrossColumnIsOneAtomicPositionOp() async throws {
        _ = try await store.applyPull(rows: [
            TaskItem.fixture(id: "00000000-0000-4000-8000-000000000021", title: "A", status: .inProgress, orderKey: "G"),
            TaskItem.fixture(id: "00000000-0000-4000-8000-000000000022", title: "B", status: .inProgress, orderKey: "V"),
            TaskItem.fixture(id: "00000000-0000-4000-8000-000000000023", title: "Dragged", status: .todo, orderKey: "V"),
        ], cursor: 3, boardEpoch: "e1")

        // Drop "Dragged" between A and B in another column.
        try await store.placeTask(id: "00000000-0000-4000-8000-000000000023", in: .inProgress, between: "G", and: "V")
        let ops = try await store.queueSnapshot()
        #expect(ops.count == 1, "one op carries the whole move")
        #expect(ops[0].payload.status == .inProgress, "status travels with the key")
        let key = try #require(ops[0].payload.orderKey)
        #expect(key > "G" && key < "V", "key minted strictly between the drop neighbors")

        // Same-column placement omits status (plain reorder).
        try await store.placeTask(id: "00000000-0000-4000-8000-000000000021", in: .inProgress, between: nil, and: "G")
        let ops2 = try await store.queueSnapshot()
        let reorder = try #require(ops2.first { $0.taskId == "00000000-0000-4000-8000-000000000021" })
        #expect(reorder.payload.status == nil)
        #expect(reorder.payload.orderKey != nil)
    }
}
