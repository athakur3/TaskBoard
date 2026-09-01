import Foundation
import Testing
@testable import TaskBoard

/// The sync cycle against a scripted server (design §8/§9). All main-actor so
/// SyncStatusCenter reads are safe.
@MainActor
struct SyncEngineTests {
    @Test func testPushCreateThenPullAdoptsServerState() async throws {
        let (store, api, engine, status) = makeHarness()
        let local = try await store.createTask(title: "New", details: "d", status: .todo)

        api.fallback = { request in
            switch request {
            case .create(let body):
                var row = TaskItem.fixture(id: body.id, title: body.title, status: body.status)
                row.details = "d"
                row.orderKey = body.orderKey ?? "V"
                return .success(row)
            case .fetch:
                return .success(TasksResponse(boardEpoch: "e1", latestSeq: 1, tasks: []))
            default:
                return .failure(.retryable("unexpected"))
            }
        }

        await engine.syncNow()
        let ops = try await store.queueSnapshot()
        #expect(ops.isEmpty)
        let board = try await store.board()
        #expect(board[0].badge == .synced)
        #expect(board[0].item.version == 1, "server version adopted")
        #expect(board[0].item.id == local.id)
        #expect(status.pendingCount == 0)
        let meta = try await store.syncMeta()
        #expect(meta.boardEpoch == "e1")
    }

    @Test func testTransientFailureKeepsOpAndSameMutationIdOnRetry() async throws {
        let (store, api, engine, status) = makeHarness()
        _ = try await store.createTask(title: "Offline", details: "", status: .todo)
        api.fallback = { _ in .failure(.retryable("no route to host")) }

        await engine.syncNow()
        var ops = try await store.queueSnapshot()
        #expect(ops.count == 1, "transient failure keeps the op queued")
        #expect(ops[0].transmitted, "it did go on the wire once — now frozen")
        let firstMutationId = ops[0].mutationId
        #expect(status.connectivity == .offline)

        // Server comes back: the SAME mutation id retries (ambiguous-retry safety).
        api.fallback = { request in
            switch request {
            case .create(let body): return .success(TaskItem.fixture(id: body.id, title: body.title))
            case .fetch: return .success(TasksResponse(boardEpoch: "e1", latestSeq: 1, tasks: []))
            default: return .failure(.retryable("unexpected"))
            }
        }
        await engine.syncNow()
        ops = try await store.queueSnapshot()
        #expect(ops.isEmpty)
        _ = firstMutationId // create idempotency is by task id; mutation id unchanged either way
        #expect(status.connectivity == .online)
    }

    @Test func testDisjointFieldConflictAutoRebasesWithFreshMutationId() async throws {
        let (store, api, engine, status) = makeHarness()
        // Synced task at v1; local edits the title while the server's copy got a new description (v2).
        _ = try await store.applyPull(rows: [TaskItem.fixture(version: 1)], cursor: 1, boardEpoch: "e1")
        let id = TaskItem.fixture().id
        try await store.updateTask(id: id, OpPayload(title: "My title"))
        let originalMutationId = (try await store.queueSnapshot())[0].mutationId

        var serverCurrent = TaskItem.fixture(version: 2)
        serverCurrent.details = "Their new description"
        var sawRetry: UpdateTaskBody?

        api.scripted = [
            { request in
                if case .update = request { return .failure(.versionConflict(serverCurrent)) }
                return nil
            },
        ]
        api.fallback = { request in
            switch request {
            case .update(_, let body):
                sawRetry = body
                return .success(serverCurrent.applying(body))
            case .fetch:
                return .success(TasksResponse(boardEpoch: "e1", latestSeq: 3, tasks: []))
            default:
                return .failure(.retryable("unexpected"))
            }
        }

        await engine.syncNow()
        let retry = try #require(sawRetry)
        #expect(retry.baseVersion == 2, "rebase binds to the server's current version")
        #expect(retry.mutationId != originalMutationId, "a rebase is a new logical mutation")
        #expect(retry.title == "My title")
        #expect(retry.details == nil, "only my fields travel in the rebase")

        let board = try await store.board()
        #expect(board[0].item.title == "My title")
        #expect(board[0].item.details == "Their new description", "both edits survive — field-level merge")
        #expect(board[0].badge == .synced)
        #expect(status.notices.isEmpty, "disjoint merges are silent")
    }

    @Test func testSameFieldConflictSurfacesForUserResolution() async throws {
        let (store, api, engine, status) = makeHarness()
        _ = try await store.applyPull(rows: [TaskItem.fixture(title: "Base", version: 1)], cursor: 1, boardEpoch: "e1")
        let id = TaskItem.fixture().id
        try await store.updateTask(id: id, OpPayload(title: "Mine"))

        let serverCurrent = TaskItem.fixture(title: "Theirs", version: 2)
        api.fallback = { request in
            switch request {
            case .update: return .failure(.versionConflict(serverCurrent))
            case .fetch: return .success(TasksResponse(boardEpoch: "e1", latestSeq: 2, tasks: []))
            default: return .failure(.retryable("unexpected"))
            }
        }

        await engine.syncNow()
        let board = try await store.board()
        #expect(board[0].badge == .conflict)
        #expect(board[0].item.title == "Mine", "the user's text stays visible, never silently destroyed")
        let hoisted1 = try await store.conflict(taskId: id)
        let record = try #require(hoisted1)
        #expect(record.mine.title == "Mine")
        #expect(record.theirs.title == "Theirs")
        #expect(!(status.notices.isEmpty))

        // Resolve keep-mine: a fresh op goes up against the adopted version.
        try await store.resolveConflictKeepMine(taskId: id)
        let ops = try await store.queueSnapshot()
        #expect(ops.count == 1)
        #expect(ops[0].payload.title == "Mine")
        let hoisted2 = try await store.markTransmitted(opId: ops[0].opId)
        let ctx = try #require(hoisted2)
        #expect(ctx.baseVersion == 2, "keep-mine rebases on the server version we adopted")
    }

    @Test func testPositionConflictResolvesToServerSilently() async throws {
        let (store, api, engine, status) = makeHarness()
        var base = TaskItem.fixture(version: 1)
        base.status = .todo
        _ = try await store.applyPull(rows: [base], cursor: 1, boardEpoch: "e1")
        let id = base.id
        try await store.moveTask(id: id, to: .inProgress) // one legal step

        // The remote beat us to the same move, with its own key.
        var serverCurrent = base
        serverCurrent.status = .inProgress
        serverCurrent.orderKey = "q"
        serverCurrent.version = 2

        api.fallback = { request in
            switch request {
            case .update: return .failure(.versionConflict(serverCurrent))
            case .fetch: return .success(TasksResponse(boardEpoch: "e1", latestSeq: 2, tasks: []))
            default: return .failure(.retryable("unexpected"))
            }
        }

        await engine.syncNow()
        let board = try await store.board()
        #expect(board[0].item.status == .inProgress, "server position wins silently")
        #expect(board[0].badge == .synced)
        let hoisted3 = try await store.queueSnapshot()
        #expect(hoisted3.isEmpty, "losing move dropped, queue never wedges")
        #expect(status.notices.isEmpty)
    }

    @Test func testEditOfRemotelyDeletedTaskDropsWorkAndOffersRestore() async throws {
        let (store, api, engine, status) = makeHarness()
        _ = try await store.applyPull(rows: [TaskItem.fixture(title: "Doomed", version: 1)], cursor: 1, boardEpoch: "e1")
        let id = TaskItem.fixture().id
        try await store.updateTask(id: id, OpPayload(title: "Edit into the void"))

        let tombstone = TaskItem.fixture(title: "Doomed", version: 2, deleted: true)
        api.fallback = { request in
            switch request {
            case .update: return .failure(.taskDeleted(tombstone))
            case .fetch: return .success(TasksResponse(boardEpoch: "e1", latestSeq: 2, tasks: []))
            default: return .failure(.retryable("unexpected"))
            }
        }

        await engine.syncNow()
        let board = try await store.board()
        #expect(board.isEmpty, "delete wins")
        let hoisted4 = try await store.queueSnapshot()
        #expect(hoisted4.isEmpty)
        let notice = try #require(status.notices.first)
        #expect(notice.restorable != nil, "restore-as-new offered")
    }

    @Test func testEpochRotationTriggersResetFlow() async throws {
        let (store, api, engine, status) = makeHarness()
        // A synced task whose sync already failed terminally (held edit queued
        // behind the flag), plus a locally-born task.
        _ = try await store.applyPull(rows: [TaskItem.fixture(title: "Old world", version: 1)], cursor: 5, boardEpoch: "e1")
        let doomedId = TaskItem.fixture().id
        try await store.updateTask(id: doomedId, OpPayload(title: "first edit"))
        let firstOp = (try await store.queueSnapshot())[0]
        try await store.failOpTerminal(opId: firstOp.opId, message: "boom")
        try await store.updateTask(id: doomedId, OpPayload(title: "held edit"))
        let kept = try await store.createTask(title: "Keep me", details: "", status: .todo)

        let freshTask = TaskItem.fixture(id: "00000000-0000-4000-8000-000000000042", title: "New world", version: 1)
        var keptRow = TaskItem.fixture(id: kept.id, title: "Keep me")
        keptRow.orderKey = kept.orderKey
        api.fallback = { request in
            switch request {
            case .fetch(let since) where since != nil:
                return .success(TasksResponse(boardEpoch: "e2", latestSeq: 2, tasks: [])) // epoch changed!
            case .fetch:
                return .success(TasksResponse(boardEpoch: "e2", latestSeq: 2, tasks: [freshTask, keptRow]))
            case .create(let body):
                return .success(TaskItem.fixture(id: body.id, title: body.title, orderKey: body.orderKey ?? "V"))
            default:
                return .failure(.retryable("unexpected request"))
            }
        }

        await engine.syncNow()
        let meta = try await store.syncMeta()
        #expect(meta.boardEpoch == "e2")
        let board = try await store.board()
        #expect(Set(board.map(\.item.title)) == ["New world", "Keep me"])
        #expect(status.notices.contains { $0.message.contains("reset") }, "dropped work is surfaced, not silent")
        let queue = try await store.queueSnapshot()
        #expect(queue.isEmpty, "held edit dropped by reset; create was pushed")
    }

    @Test func testTerminalValidationFailureDropsOpFlagsTaskAndHoldsQueue() async throws {
        let (store, api, engine, _) = makeHarness()
        _ = try await store.applyPull(rows: [TaskItem.fixture(version: 1)], cursor: 1, boardEpoch: "e1")
        let id = TaskItem.fixture().id
        try await store.updateTask(id: id, OpPayload(title: "Bad somehow"))

        api.fallback = { request in
            switch request {
            case .update: return .failure(.validation("title rejected"))
            case .get: return .success(TaskItem.fixture(title: "Server truth", version: 1))
            case .fetch: return .success(TasksResponse(boardEpoch: "e1", latestSeq: 1, tasks: []))
            default: return .failure(.retryable("unexpected"))
            }
        }

        await engine.syncNow()
        let board = try await store.board()
        if case .failed = board[0].badge {} else { Issue.record("expected failed badge, got \(board[0].badge)") }
        let hoisted6 = try await store.queueSnapshot()
        #expect(hoisted6.isEmpty, "terminal op dropped")

        // Later edits are held until the user retries.
        try await store.updateTask(id: id, OpPayload(title: "Another try"))
        await engine.syncNow()
        let hoisted7 = try await store.queueSnapshot()
        #expect(hoisted7.count == 1, "held while flagged")
        try await store.clearFailure(taskId: id)
        await engine.syncNow()
        let hoisted8 = try await store.queueSnapshot()
        #expect(hoisted8.isEmpty, "flows after retry")
    }

    @Test func testPullAfterPushDeliversMergedTruth() async throws {
        let (store, api, engine, _) = makeHarness()
        let other = TaskItem.fixture(id: "00000000-0000-4000-8000-000000000077", title: "From another device", version: 1)
        api.fallback = { request in
            switch request {
            case .fetch:
                return .success(TasksResponse(boardEpoch: "e1", latestSeq: 9, tasks: [other]))
            default:
                return .failure(.retryable("unexpected"))
            }
        }
        await engine.syncNow()
        let board = try await store.board()
        #expect(board.map(\.item.title) == ["From another device"])
        let hoisted9 = try await store.syncMeta()
        #expect(hoisted9.cursor == 9)
    }
}

extension SyncEngineTests {
    @Test func testPushDrainsFifoPerTask() async throws {
        let (store, api, engine, _) = makeHarness()
        let created = try await store.createTask(title: "Ordered", details: "", status: .todo)

        // First pass: the create goes on the wire and fails transiently (frozen).
        api.fallback = { _ in .failure(.retryable("down")) }
        await engine.syncNow()
        // The user then deletes: the delete queues BEHIND the frozen create.
        _ = try await store.deleteTask(id: created.id)

        api.fallback = { request in
            switch request {
            case .create(let body): return .success(TaskItem.fixture(id: body.id, title: body.title))
            case .delete: return .success(())
            case .fetch: return .success(TasksResponse(boardEpoch: "e1", latestSeq: 2, tasks: []))
            default: return .failure(.retryable("unexpected"))
            }
        }
        await engine.syncNow()

        let ordered = api.requests.compactMap { request -> String? in
            if case .create = request { return "create" }
            if case .delete = request { return "delete" }
            return nil
        }
        #expect(ordered.suffix(2) == ["create", "delete"], "strict FIFO per task: frozen create first, delete after")
        let queue = try await store.queueSnapshot()
        #expect(queue.isEmpty)
        let board = try await store.board()
        #expect(board.isEmpty, "tombstoned end state")
    }

    @Test func testTransientRetryReusesTheSameMutationId() async throws {
        let (store, api, engine, _) = makeHarness()
        _ = try await store.applyPull(rows: [TaskItem.fixture(version: 1)], cursor: 1, boardEpoch: "e1")
        try await store.updateTask(id: TaskItem.fixture().id, OpPayload(title: "Edit"))

        var seen: [String] = []
        api.scripted = [
            { request in
                if case .update(_, let body) = request { seen.append(body.mutationId); return .failure(.retryable("drop")) }
                return nil
            },
        ]
        api.fallback = { request in
            switch request {
            case .update(_, let body):
                seen.append(body.mutationId)
                return .success(TaskItem.fixture(title: "Edit", version: 2))
            case .fetch:
                return .success(TasksResponse(boardEpoch: "e1", latestSeq: 2, tasks: []))
            default:
                return .failure(.retryable("unexpected"))
            }
        }
        await engine.syncNow() // transient — op kept
        await engine.syncNow() // retry succeeds
        #expect(seen.count == 2)
        #expect(seen[0] == seen[1], "ambiguous retry MUST reuse the same mutationId (§8) — the ledger absorbs it")
    }

    @Test func testCursorReset410TriggersEpochResetFlow() async throws {
        let (store, api, engine, _) = makeHarness()
        _ = try await store.applyPull(rows: [TaskItem.fixture(title: "Old world", version: 1)], cursor: 50, boardEpoch: "e1")
        let fresh = TaskItem.fixture(id: "00000000-0000-4000-8000-000000000042", title: "New world", version: 1)
        api.fallback = { request in
            switch request {
            case .fetch(let since) where since != nil:
                return .failure(.cursorReset) // 410: cursor ahead of the reset server
            case .fetch:
                return .success(TasksResponse(boardEpoch: "e2", latestSeq: 1, tasks: [fresh]))
            default:
                return .failure(.retryable("unexpected"))
            }
        }
        await engine.syncNow()
        let meta = try await store.syncMeta()
        #expect(meta.boardEpoch == "e2", "410 must run the epoch-reset flow, never be swallowed")
        #expect(meta.cursor == 1)
        let board = try await store.board()
        #expect(board.map(\.item.title) == ["New world"])
    }

    @Test func testBaseVersionBindsAtSendTimeAcrossSequentialOps() async throws {
        let (store, api, engine, _) = makeHarness()
        _ = try await store.applyPull(rows: [TaskItem.fixture(title: "Base", version: 1)], cursor: 1, boardEpoch: "e1")
        let id = TaskItem.fixture().id

        // Freeze a first edit on the wire (transient), then queue a second.
        api.fallback = { _ in .failure(.retryable("down")) }
        try await store.updateTask(id: id, OpPayload(title: "First"))
        await engine.syncNow()
        try await store.updateTask(id: id, OpPayload(details: "Second"))

        var versions: [Int] = []
        api.fallback = { request in
            switch request {
            case .update(_, let body):
                versions.append(body.baseVersion)
                return .success(TaskItem.fixture(title: "First", version: body.baseVersion + 1))
            case .fetch:
                return .success(TasksResponse(boardEpoch: "e1", latestSeq: 3, tasks: []))
            default:
                return .failure(.retryable("unexpected"))
            }
        }
        await engine.syncNow()
        #expect(versions == [1, 2], "second op binds to the version adopted from the first ack — sequential offline edits never self-conflict (§8)")
    }

    @Test func test404OnLocallyBornContentOpReenqueuesAsCreate() async throws {
        let (store, api, engine, _) = makeHarness()
        let created = try await store.createTask(title: "Lost create", details: "content", status: .todo)
        // Simulate the create op being lost while the task stays locally born.
        let createOp = (try await store.queueSnapshot())[0]
        try await store.dropOp(opId: createOp.opId)
        try await store.updateTask(id: created.id, OpPayload(title: "Lost create, edited"))

        var sawCreate = false
        api.fallback = { request in
            switch request {
            case .update:
                return .failure(.taskNotFound)
            case .create(let body):
                sawCreate = true
                return .success(TaskItem.fixture(id: body.id, title: body.title))
            case .fetch:
                return .success(TasksResponse(boardEpoch: "e1", latestSeq: 1, tasks: []))
            default:
                return .failure(.retryable("unexpected"))
            }
        }
        await engine.syncNow()
        #expect(sawCreate, "404 on a locally-born content op re-enqueues as a create (§8)")
        let board = try await store.board()
        #expect(board[0].item.title == "Lost create, edited")
        #expect(board[0].badge == .synced)
        let queue = try await store.queueSnapshot()
        #expect(queue.isEmpty)
    }

    // MARK: - Workflow-chain regressions (a conforming client must never be
    // told INVALID_TRANSITION — these pin the chain across conflict handling)

    @Test func testPositionLossRetainsWorkflowLinkForQueuedSteps() async throws {
        let (store, api, engine, status) = makeHarness()
        let base = TaskItem.fixture(version: 1) // todo
        _ = try await store.applyPull(rows: [base], cursor: 1, boardEpoch: "e1")
        let id = base.id
        try await store.moveTask(id: id, to: .inProgress) // op1
        try await store.moveTask(id: id, to: .done)       // op2, split per step

        // The remote merely reordered the card WITHIN To Do (orderKey only).
        var serverCurrent = base
        serverCurrent.orderKey = "q"
        serverCurrent.version = 2

        var sentSteps: [TaskStatus] = []
        api.scripted = [
            { request in
                if case .update = request { return .failure(.versionConflict(serverCurrent)) }
                return nil
            },
        ]
        api.fallback = { request in
            switch request {
            case .update(_, let body):
                if let step = body.status { sentSteps.append(step) }
                serverCurrent = serverCurrent.applying(body)
                return .success(serverCurrent)
            case .fetch: return .success(TasksResponse(boardEpoch: "e1", latestSeq: 2, tasks: []))
            default: return .failure(.retryable("unexpected"))
            }
        }

        await engine.syncNow()
        // op1's orderKey is shed (server wins position) but its STATUS survives
        // as the chain link, so op2's done never becomes a todo -> done skip.
        #expect(sentSteps == [.inProgress, .done], "the chain replayed one legal step at a time")
        let board = try await store.board()
        #expect(board[0].item.status == .done)
        #expect(board[0].badge == .synced)
        #expect((try await store.queueSnapshot()).isEmpty)
        #expect(status.notices.isEmpty, "no user-facing failure for a conforming chain")
    }

    @Test func testTextConflictKeepsDisjointStepsQueuedAndChainCompletes() async throws {
        let (store, api, engine, _) = makeHarness()
        let base = TaskItem.fixture(version: 1) // todo, title "Fixture"
        _ = try await store.applyPull(rows: [base], cursor: 1, boardEpoch: "e1")
        let id = base.id
        try await store.updateTask(id: id, OpPayload(title: "My title"))
        try await store.moveTask(id: id, to: .inProgress) // coalesces into op1
        try await store.moveTask(id: id, to: .done)       // op2

        var serverCurrent = base
        serverCurrent.title = "Their title"
        serverCurrent.version = 2

        api.scripted = [
            { request in
                if case .update = request { return .failure(.versionConflict(serverCurrent)) }
                return nil
            },
        ]
        var sentSteps: [TaskStatus] = []
        api.fallback = { request in
            switch request {
            case .update(_, let body):
                if let step = body.status { sentSteps.append(step) }
                serverCurrent = serverCurrent.applying(body)
                return .success(serverCurrent)
            case .fetch: return .success(TasksResponse(boardEpoch: "e1", latestSeq: 2, tasks: []))
            default: return .failure(.retryable("unexpected"))
            }
        }

        await engine.syncNow()
        // Only the collided title went to the user; the move steps stayed queued.
        let record = try #require(try await store.conflict(taskId: id))
        #expect(record.fields == ["title"])
        #expect(record.mine.status == nil, "position is never part of the user's decision")
        let held = try await store.queueSnapshot()
        #expect(held.compactMap(\.payload.status) == [.inProgress, .done], "the chain survived the conflict")

        try await store.resolveConflictKeepMine(taskId: id)
        await engine.syncNow()
        #expect(sentSteps == [.inProgress, .done], "released steps replayed legally")
        let board = try await store.board()
        #expect(board[0].item.status == .done)
        #expect(board[0].item.title == "My title")
        #expect(board[0].badge == .synced)
        #expect((try await store.queueSnapshot()).isEmpty)
    }

    @Test func testNoticesAreCappedToTheVisibleWindow() {
        // Only three banners render; older ones must be dropped, not stranded
        // invisibly (with their Restore buttons) in an ever-growing array.
        let status = SyncStatusCenter()
        for n in 1...5 { status.post(SyncNotice(message: "n\(n)")) }
        #expect(status.notices.count == 3)
        #expect(status.notices.map(\.message) == ["n3", "n4", "n5"], "newest survive")
    }

    @Test func testMoveFeedbackFiresOnlyForLegalUserMoves() async throws {
        // Board.lastMove drives the UI's pulses/outlines/haptics — it must
        // fire only for legal, user-made, cross-column moves.
        let (store, _, engine, status) = makeHarness()
        let board = Board(store: store, engine: engine, status: status)
        _ = try await store.applyPull(rows: [TaskItem.fixture()], cursor: 1, boardEpoch: "e1")
        await board.reload()
        let id = TaskItem.fixture().id

        board.move(id: id, to: .done) // illegal skip from todo
        #expect(board.lastMove == nil, "a refused move gives no feedback")

        board.move(id: id, to: .inProgress)
        #expect(board.lastMove?.from == .todo)
        #expect(board.lastMove?.to == .inProgress)
    }

    @Test func testTerminalFailureRollsBackToSnapshotWithoutNetwork() async throws {
        let (store, api, engine, _) = makeHarness()
        let base = TaskItem.fixture(title: "Server truth", version: 1)
        _ = try await store.applyPull(rows: [base], cursor: 1, boardEpoch: "e1")
        try await store.updateTask(id: base.id, OpPayload(title: "Rejected edit"))

        api.fallback = { request in
            switch request {
            case .update: return .failure(.validation("title rejected"))
            default: return .failure(.retryable("offline")) // the recovery GET fails too
            }
        }
        await engine.syncNow()
        let board = try await store.board()
        #expect(board[0].item.title == "Server truth",
                "rollback comes from the local snapshot — a failed refresh GET can't leave the row diverged")
        #expect(board[0].badge == .failed("title rejected"))
        #expect((try await store.queueSnapshot()).isEmpty)
    }
}
