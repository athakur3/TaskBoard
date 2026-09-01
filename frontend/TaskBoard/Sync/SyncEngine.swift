import Foundation
import Network

/// The sync engine (design §8): push the offline queue strictly FIFO, then pull
/// the delta. All conflict arbitration data comes from the server's 409
/// responses; resolution here is deterministic and never reads a clock.
actor SyncEngine {
    private let store: LocalStore
    private let api: TaskAPI
    private let status: SyncStatusCenter

    private var isSyncing = false
    private var rerunRequested = false // a kick that lands mid-cycle runs after it
    private var failureStreak = 0
    private var nextAttemptAt = Date.distantPast
    private var periodicTask: Task<Void, Never>?
    private var monitor: NWPathMonitor?

    /// Caps a single push pass; combined with the per-op rebaseCount cap (3)
    /// this bounds work even under pathological conflict storms.
    private let maxOpsPerPass = 200

    init(store: LocalStore, api: TaskAPI, status: SyncStatusCenter) {
        self.store = store
        self.api = api
        self.status = status
    }

    // MARK: - Triggers

    /// Periodic timer + reachability. Not started in unit tests.
    func start() {
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.kick(userInitiated: false)
            }
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let engine = self else { return }
            Task { await engine.pathChanged(satisfied: path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "sync.pathmonitor"))
    }

    private var pathWasSatisfied = true // the monitor's FIRST callback is a report, not a regain

    /// Kick only on the unsatisfied → satisfied transition — the monitor's
    /// initial report and same-status path churn are not regains.
    private func pathChanged(satisfied: Bool) async {
        let regained = satisfied && !pathWasSatisfied
        pathWasSatisfied = satisfied
        if regained {
            await kick(userInitiated: true) // connectivity regained: bypass backoff
        }
    }

    private var lastSuccessAt = Date.distantPast

    /// Requests a sync cycle. Exponential backoff (1s→60s) gates automatic
    /// retries; user-initiated syncs bypass it. A kick within 2s of a
    /// successful cycle with nothing queued is absorbed — launch fires
    /// several triggers at once.
    func kick(userInitiated: Bool) async {
        if !userInitiated && Date() < nextAttemptAt { return }
        if Date().timeIntervalSince(lastSuccessAt) < 2,
           ((try? await store.pendingOpCount()) ?? 1) == 0 { return }
        await syncNow()
    }

    // MARK: - The cycle

    /// Push then pull (design §8): conflicts surface exactly once; the pull
    /// delivers merged truth. A kick landing mid-cycle is latched, and the
    /// rerun fires only when queued work exists — a mutation made mid-pull
    /// must not wait for the 30s timer, but a redundant trigger must not buy
    /// an empty extra pull.
    func syncNow() async {
        guard !isSyncing else {
            rerunRequested = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        var rerun = false
        repeat {
            rerunRequested = false
            await MainActor.run { status.isSyncing = true }

            let pushOutcome = await push()
            var pullOK = false
            if pushOutcome != .paused {
                pullOK = await pull()
            }

            let pending = (try? await store.pendingOpCount()) ?? 0
            let succeeded = pushOutcome == .completed && pullOK
            if succeeded {
                failureStreak = 0
                nextAttemptAt = .distantPast
                lastSuccessAt = Date()
            } else {
                failureStreak += 1
                let delay = min(60.0, pow(2.0, Double(failureStreak - 1)))
                nextAttemptAt = Date().addingTimeInterval(delay)
            }
            await MainActor.run {
                status.isSyncing = false
                status.pendingCount = pending
                status.connectivity = succeeded ? .online : .offline
            }
            rerun = rerunRequested
            if rerun { rerun = ((try? await store.pendingOpCount()) ?? 0) > 0 }
        } while rerun
    }

    // MARK: - Push

    private enum PushOutcome { case completed, paused }

    private func push() async -> PushOutcome {
        var processed = 0
        while processed < maxOpsPerPass {
            guard let ops = try? await store.queueSnapshot(), !ops.isEmpty else { return .completed }
            // First op whose task is not held; held tasks wait for the user.
            var candidate: LocalStore.SendContext?
            for op in ops {
                if let ctx = try? await store.markTransmitted(opId: op.opId), !ctx.held {
                    candidate = ctx
                    break
                }
            }
            guard let ctx = candidate else { return .completed }
            processed += 1
            switch await send(ctx) {
            case .advanced:
                continue
            case .pauseSync:
                return .paused
            }
        }
        return .completed
    }

    private enum OpResult { case advanced, pauseSync(String) }

    private func send(_ ctx: LocalStore.SendContext) async -> OpResult {
        let op = ctx.op
        do {
            switch op.kind {
            case .create:
                // payloadFromRow always fills these; the fallbacks mirror the
                // server's own defaults, so a broken invariant surfaces as a
                // validation failure instead of a silent rename.
                let body = CreateTaskBody(
                    id: op.taskId,
                    title: op.payload.title ?? "",
                    status: op.payload.status ?? .todo,
                    orderKey: op.payload.orderKey,
                    createdAt: op.payload.createdAt ?? WireDate.now(),
                    details: op.payload.details ?? ""
                )
                let row = try await api.create(body)
                if row.deleted {
                    // POST onto a tombstone: acknowledged-then-deleted-remotely
                    // (server contract §6). Delete stays trustworthy.
                    let last = try? await store.taskDeletedRemotely(taskId: op.taskId)
                    await notifyDeletedRemotely(last ?? nil)
                } else {
                    try await store.completeOp(opId: op.opId, serverRow: row)
                }
                return .advanced

            case .update:
                let body = UpdateTaskBody(
                    baseVersion: max(1, ctx.baseVersion),
                    mutationId: op.mutationId,
                    title: op.payload.title,
                    details: op.payload.details,
                    status: op.payload.status,
                    orderKey: op.payload.orderKey
                )
                let row = try await api.update(id: op.taskId, body)
                try await store.completeOp(opId: op.opId, serverRow: row)
                return .advanced

            case .delete:
                try await api.delete(id: op.taskId)
                try await store.completeDelete(opId: op.opId, taskId: op.taskId)
                return .advanced
            }
        } catch let error as APIClientError {
            return await handle(error, ctx: ctx)
        } catch {
            return .pauseSync(error.localizedDescription)
        }
    }

    private func handle(_ error: APIClientError, ctx: LocalStore.SendContext) async -> OpResult {
        let op = ctx.op
        do {
            switch error {
            case .retryable(let message), .malformedResponse(let message):
                return .pauseSync(message)

            case .versionConflict(let current):
                try await adjudicateConflict(op: op, base: ctx.base, current: current)
                return .advanced

            case .taskDeleted:
                // Delete wins (design §9 row 3): drop local work, surface it.
                let last = try await store.taskDeletedRemotely(taskId: op.taskId)
                await notifyDeletedRemotely(last)
                return .advanced

            case .taskNotFound:
                if op.kind == .delete {
                    // Absorbing anyway; treat as done.
                    try await store.completeDelete(opId: op.opId, taskId: op.taskId)
                } else if ctx.locallyBorn {
                    if op.payload.title != nil || op.payload.details != nil {
                        // The create was lost: re-enqueue as a create (design §8).
                        try await store.convertOpToCreate(opId: op.opId)
                    } else {
                        try await store.dropOp(opId: op.opId) // reorder-only: dropped
                    }
                } else {
                    // A synced task the server has never heard of (e.g. the
                    // server was reset): terminal — flag it, never drop silently.
                    try await store.failOpTerminal(opId: op.opId, message: "Task no longer exists on the server")
                }
                return .advanced

            case .validation(let message):
                try await store.failOpTerminal(opId: op.opId, message: message)
                await refreshFromServer(taskId: op.taskId)
                return .advanced

            case .cursorReset:
                return .pauseSync("Unexpected cursor reset on push")
            }
        } catch {
            return .pauseSync(error.localizedDescription)
        }
    }

    /// Design §9: field-disjoint edits auto-merge; same-field text conflicts go
    /// to the user; position conflicts resolve to the server silently.
    private func adjudicateConflict(op: PendingOp, base: TaskItem?, current: TaskItem) async throws {
        var remoteChanged = Set<String>()
        if let base {
            if current.title != base.title { remoteChanged.insert("title") }
            if current.details != base.details { remoteChanged.insert("details") }
            if current.status != base.status || current.orderKey != base.orderKey { remoteChanged.insert("position") }
        } else {
            remoteChanged = ["title", "details", "position"]
        }
        let mineChanged = op.payload.changedFields
        let overlap = mineChanged.intersection(remoteChanged)
        let textOverlap = overlap.intersection(["title", "details"])

        if !textOverlap.isEmpty {
            try await store.recordConflict(opId: op.opId, mine: op.payload, theirs: current,
                                           fields: Array(textOverlap).sorted(),
                                           positionLost: overlap.contains("position"))
            await MainActor.run {
                status.post(SyncNotice(kind: .warning, message: "“\(current.title)” was edited on another device — tap its badge to resolve."))
            }
            return
        }

        if overlap.contains("position") {
            // Positions are low-stakes and instantly redoable: server wins
            // silently (design §9 rows 7–8) — this also covers the stale
            // orderKey-context case, since a cross-column move changes position.
            // The store still preserves this op's status when steps queued
            // behind it need it as their workflow link.
            var stripped = op.payload
            stripped.status = nil
            stripped.orderKey = nil
            try await store.rebaseAfterPositionLoss(opId: op.opId, keeping: stripped,
                                                    shedStatus: op.payload.status, against: current)
            return
        }
        if op.payload.isEmpty {
            try await store.completeOp(opId: op.opId, serverRow: current)
            return
        }
        if op.rebaseCount >= 3 {
            try await store.failOpTerminal(opId: op.opId, message: "Repeated conflicts — edit again to retry")
            return
        }
        try await store.rebaseOp(opId: op.opId, newPayload: op.payload, against: current)
    }

    private func refreshFromServer(taskId: String) async {
        guard let row = try? await api.getTask(id: taskId) else { return }
        if row.deleted {
            let last = try? await store.taskDeletedRemotely(taskId: taskId)
            await notifyDeletedRemotely(last ?? nil)
        } else {
            try? await store.applyServerRow(row)
        }
    }

    private func notifyDeletedRemotely(_ last: TaskItem?) async {
        guard let last else { return }
        await MainActor.run {
            status.post(SyncNotice(kind: .warning,
                                   message: "“\(last.title)” was deleted on another device.",
                                   restorable: last))
        }
    }

    // MARK: - Pull

    private func pull() async -> Bool {
        do {
            let meta = try await store.syncMeta()
            if meta.boardEpoch == nil {
                // First-ever sync: cold fetch (design §8).
                let response = try await api.fetchTasks(since: nil)
                _ = try await store.applyPull(rows: response.tasks, cursor: response.latestSeq, boardEpoch: response.boardEpoch)
                return true
            }
            let response = try await api.fetchTasks(since: meta.cursor)
            if response.boardEpoch != meta.boardEpoch {
                try await epochReset()
                return true
            }
            let outcome = try await store.applyPull(rows: response.tasks, cursor: response.latestSeq, boardEpoch: response.boardEpoch)
            await announceRemoteDeletes(outcome.deletedRemotely)
            return true
        } catch APIClientError.cursorReset {
            do {
                try await epochReset()
                return true
            } catch {
                return false
            }
        } catch {
            return false
        }
    }

    /// The epoch rule (design §8): the server was reset under us. Locally-born
    /// pending creates survive and re-push; everything else re-bases on the
    /// fresh snapshot; the drop is surfaced, never silent.
    private func epochReset() async throws {
        let cold = try await api.fetchTasks(since: nil)
        let outcome = try await store.applyEpochReset(snapshot: cold.tasks, cursor: cold.latestSeq, boardEpoch: cold.boardEpoch)
        if outcome.droppedOps > 0 {
            await MainActor.run {
                status.post(SyncNotice(kind: .warning,
                                       message: "The server was reset — \(outcome.droppedOps) unsynced change(s) to previously synced tasks were discarded."))
            }
        }
        _ = await push() // kept creates go up immediately
    }

    /// One styling for the delete-wins event regardless of which sync phase
    /// discovered it (push 409 or pull tombstone).
    private func announceRemoteDeletes(_ deleted: [TaskItem]) async {
        for item in deleted {
            await notifyDeletedRemotely(item)
        }
    }
}
