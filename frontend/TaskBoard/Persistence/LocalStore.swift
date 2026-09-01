import CoreData
import Foundation

extension Notification.Name {
    static let localStoreDidChange = Notification.Name("localStoreDidChange")
}

/// The repository. All Core Data access is serialized through one private-queue
/// context; every mutation is one save (= one SQLite transaction), which is
/// what makes "apply pulled rows + persist cursor atomically" (design §8) hold.
/// The UI and sync engine only ever see value types, never managed objects.
final class LocalStore: @unchecked Sendable {
    private let container: NSPersistentContainer
    private let context: NSManagedObjectContext

    init(inMemory: Bool = false) {
        container = PersistenceController.makeContainer(inMemory: inMemory)
        context = container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
    }

    // MARK: - Plumbing

    private func perform<T>(_ block: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        try await context.perform { [context] in
            let result = try block(context)
            if context.hasChanges {
                try context.save()
                NotificationCenter.default.post(name: .localStoreDidChange, object: nil)
            }
            return result
        }
    }

    // Fetch helpers THROW: a store I/O error must surface as an error (the
    // sync engine retries), never be misread as "no results" — e.g. a failed
    // meta read minting a duplicate counter that reuses live op ids.
    private static func fetchTask(_ id: String, in context: NSManagedObjectContext) throws -> CDTask? {
        let request = NSFetchRequest<CDTask>(entityName: "CDTask")
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func fetchOps(taskId: String? = nil, in context: NSManagedObjectContext) throws -> [CDPendingOp] {
        let request = NSFetchRequest<CDPendingOp>(entityName: "CDPendingOp")
        if let taskId { request.predicate = NSPredicate(format: "taskId == %@", taskId) }
        request.sortDescriptors = [NSSortDescriptor(key: "opId", ascending: true)]
        return try context.fetch(request)
    }

    private static func fetchOp(_ opId: Int64, in context: NSManagedObjectContext) throws -> CDPendingOp? {
        let request = NSFetchRequest<CDPendingOp>(entityName: "CDPendingOp")
        request.predicate = NSPredicate(format: "opId == %lld", opId)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// Largest order key in a column (nil for an empty column), optionally
    /// ignoring one task — the shared basis for "append at column end".
    private static func maxOrderKey(in status: TaskStatus, excluding id: String? = nil, context: NSManagedObjectContext) throws -> String? {
        let request = NSFetchRequest<CDTask>(entityName: "CDTask")
        if let id {
            request.predicate = NSPredicate(format: "status == %@ AND locallyDeleted == NO AND id != %@", status.rawValue, id)
        } else {
            request.predicate = NSPredicate(format: "status == %@ AND locallyDeleted == NO", status.rawValue)
        }
        return try context.fetch(request).map(\.orderKey).max()
    }

    private static func meta(in context: NSManagedObjectContext) throws -> CDSyncMeta {
        let request = NSFetchRequest<CDSyncMeta>(entityName: "CDSyncMeta")
        request.fetchLimit = 1
        if let existing = try context.fetch(request).first { return existing }
        let m = CDSyncMeta(entity: NSEntityDescription.entity(forEntityName: "CDSyncMeta", in: context)!, insertInto: context)
        m.cursor = 0
        m.nextOpId = 1
        return m
    }

    private static func nextOpId(in context: NSManagedObjectContext) throws -> Int64 {
        let m = try meta(in: context)
        let id = m.nextOpId
        m.nextOpId += 1
        return id
    }

    /// The ONLY way a queue entry is minted: monotonic opId from the counter,
    /// fresh lowercase-UUID mutationId. (`mutationId` has no model default — a
    /// bespoke construction that forgot it would crash at save time.)
    private static func enqueueOp(kind: OpKind, taskId: String, payload: OpPayload, in context: NSManagedObjectContext) throws {
        let op = CDPendingOp(entity: NSEntityDescription.entity(forEntityName: "CDPendingOp", in: context)!, insertInto: context)
        op.opId = try nextOpId(in: context)
        op.taskId = taskId
        op.kind = kind.rawValue
        op.mutationId = UUID().uuidString.lowercased()
        op.payloadJSON = OpPayload.encode(payload)
    }

    private static func asItem(_ t: CDTask) -> TaskItem {
        TaskItem(
            id: t.id, title: t.title, details: t.details,
            status: TaskStatus(rawValue: t.status) ?? .todo,
            orderKey: t.orderKey, version: Int(t.version),
            deleted: false, createdAt: t.createdAt, updatedAt: t.updatedAt
        )
    }

    private static func asOp(_ o: CDPendingOp) -> PendingOp {
        PendingOp(
            opId: o.opId, taskId: o.taskId, kind: OpKind(rawValue: o.kind) ?? .update,
            payload: OpPayload.decode(o.payloadJSON), mutationId: o.mutationId,
            transmitted: o.transmitted, rebaseCount: Int(o.rebaseCount)
        )
    }

    private static func applyServerFields(_ row: TaskItem, to t: CDTask) {
        t.title = row.title
        t.details = row.details
        t.status = row.status.rawValue
        t.orderKey = row.orderKey
        t.createdAt = row.createdAt
        t.updatedAt = row.updatedAt
        t.version = Int64(row.version)
    }

    /// The board-visibility invariant, in ONE place: visible fields = server
    /// base + every queued optimistic payload, oldest first. Callers update
    /// version/syncedSnapshot themselves.
    private static func reprojectVisibleFields(_ t: CDTask, base: TaskItem, in context: NSManagedObjectContext) throws {
        guard !t.locallyDeleted else { return }
        applyServerFields(base, to: t)
        for op in try fetchOps(taskId: t.id, in: context) {
            let payload = OpPayload.decode(op.payloadJSON)
            if let v = payload.title { t.title = v }
            if let v = payload.details { t.details = v }
            if let v = payload.status { t.status = v.rawValue }
            if let v = payload.orderKey { t.orderKey = v }
        }
    }

    // MARK: - Workflow-chain invariant

    /// Replaying `steps` in order from `base` must take only legal transitions.
    private static func chainIsLegal(from base: TaskStatus, steps: [TaskStatus]) -> Bool {
        var running = base
        for step in steps {
            guard running.canMove(to: step) else { return false }
            running = step
        }
        return true
    }

    /// True when the ops queued after `opId` need `link` as their starting
    /// status: illegal straight from the adopted base, legal via the link.
    private static func laterOpsNeedLink(after opId: Int64, taskId: String, base: TaskStatus,
                                         link: TaskStatus, in context: NSManagedObjectContext) throws -> Bool {
        let laterSteps = try fetchOps(taskId: taskId, in: context)
            .filter { $0.opId > opId }
            .compactMap { OpPayload.decode($0.payloadJSON).status }
        guard !laterSteps.isEmpty else { return false }
        return !chainIsLegal(from: base, steps: laterSteps) && chainIsLegal(from: link, steps: laterSteps)
    }

    /// Last-resort chain repair (terminal failures): strip any status step no
    /// longer legal from `base`, so a held queue can never replay a skip.
    /// Lossy; the lossless path is retaining the link via `laterOpsNeedLink`.
    private static func stripIllegalSteps(taskId: String, base: TaskStatus, in context: NSManagedObjectContext) throws {
        var running = base
        for op in try fetchOps(taskId: taskId, in: context) {
            var payload = OpPayload.decode(op.payloadJSON)
            guard let step = payload.status else { continue }
            if op.kind == OpKind.create.rawValue || running.canMove(to: step) {
                running = step
                continue
            }
            payload.status = nil
            payload.orderKey = nil
            if payload.isEmpty {
                context.delete(op)
            } else {
                op.payloadJSON = OpPayload.encode(payload)
            }
        }
    }

    /// A create payload snapshotting the row as it stands (re-enqueued or
    /// converted creates).
    private static func payloadFromRow(_ t: CDTask) -> OpPayload {
        OpPayload(title: t.title, details: t.details,
                  status: TaskStatus(rawValue: t.status), orderKey: t.orderKey,
                  createdAt: t.createdAt)
    }

    /// Insert a fresh local row for a never-seen server row.
    private static func insertTask(from row: TaskItem, in context: NSManagedObjectContext) {
        let t = CDTask(entity: NSEntityDescription.entity(forEntityName: "CDTask", in: context)!, insertInto: context)
        t.id = row.id
        applyServerFields(row, to: t)
        t.locallyBorn = false
        t.syncedSnapshot = encodeSnapshot(row)
    }

    private static func clampTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(500))
        return capped.isEmpty ? "(untitled)" : capped
    }

    private static func clampDetails(_ value: String) -> String {
        String(value.prefix(4000))
    }

    private static func encodeSnapshot(_ row: TaskItem) -> String {
        String(data: try! JSONEncoder().encode(row), encoding: .utf8)!
    }

    private static func decodeSnapshot(_ json: String?) -> TaskItem? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(TaskItem.self, from: Data(json.utf8))
    }

    // MARK: - Reads

    /// Board contents in render order: (status, orderKey, id) — the same total
    /// order every replica computes (design §10).
    func board() async throws -> [BoardTask] {
        try await perform { context in
            let request = NSFetchRequest<CDTask>(entityName: "CDTask")
            request.predicate = NSPredicate(format: "locallyDeleted == NO")
            request.sortDescriptors = [
                NSSortDescriptor(key: "status", ascending: true),
                NSSortDescriptor(key: "orderKey", ascending: true),
                NSSortDescriptor(key: "id", ascending: true),
            ]
            let tasks = try context.fetch(request)
            let allOps = try Self.fetchOps(in: context)
            var opCounts: [String: Int] = [:]
            for op in allOps { opCounts[op.taskId, default: 0] += 1 }
            return tasks.map { t in
                let badge: TaskSyncBadge
                if t.conflictJSON != nil { badge = .conflict }
                else if let flag = t.syncFlag { badge = .failed(flag) }
                else if opCounts[t.id, default: 0] > 0 { badge = .pending }
                else { badge = .synced }
                return BoardTask(item: Self.asItem(t), badge: badge)
            }
        }
    }

    func task(id: String) async throws -> TaskItem? {
        try await perform { context in
            try Self.fetchTask(id, in: context).map(Self.asItem)
        }
    }

    func conflict(taskId: String) async throws -> ConflictRecord? {
        try await perform { context in
            return ConflictRecord.decode(try Self.fetchTask(taskId, in: context)?.conflictJSON)
        }
    }

    func syncMeta() async throws -> (cursor: Int, boardEpoch: String?) {
        try await perform { context in
            let m = try Self.meta(in: context)
            return (Int(m.cursor), m.boardEpoch)
        }
    }

    func pendingOpCount() async throws -> Int {
        try await perform { context in
            try Self.fetchOps(in: context).count
        }
    }

    // MARK: - Local mutations (optimistic write + queue, per design §8)

    /// Creates a task locally at the end of its column and queues the create.
    @discardableResult
    func createTask(title: String, details: String, status: TaskStatus) async throws -> TaskItem {
        try await perform { context in
            let orderKey = OrderKey.after(try Self.maxOrderKey(in: status, context: context))
            let now = WireDate.now()
            let id = UUID().uuidString.lowercased()

            let t = CDTask(entity: NSEntityDescription.entity(forEntityName: "CDTask", in: context)!, insertInto: context)
            t.id = id
            t.title = Self.clampTitle(title)
            t.details = Self.clampDetails(details)
            t.status = status.rawValue
            t.orderKey = orderKey
            t.version = 0
            t.createdAt = now
            t.updatedAt = now
            t.locallyBorn = true

            try Self.enqueueOp(kind: .create, taskId: id, payload: Self.payloadFromRow(t), in: context)
            return Self.asItem(t)
        }
    }

    /// Optimistic edit + queue, one transaction.
    func updateTask(id: String, _ fields: OpPayload) async throws {
        var fields = fields
        if let title = fields.title { fields.title = Self.clampTitle(title) }
        if let details = fields.details { fields.details = Self.clampDetails(details) }
        try await perform { context in
            try Self.applyLocalEdit(id: id, fields, in: context)
        }
    }

    /// The coalesce-or-enqueue core (design §8, mandatory). Merge only into the
    /// newest op for this task and only while it is untransmitted; a transmitted
    /// op is frozen and later edits enqueue behind it. (A rebase deliberately
    /// re-opens coalescing by clearing `transmitted` under a fresh mutationId.)
    /// Must run inside `perform`; callers own clamping.
    private static func applyLocalEdit(id: String, _ fields: OpPayload, in context: NSManagedObjectContext) throws {
        guard let t = try fetchTask(id, in: context), !t.locallyDeleted else { return }
        if let v = fields.title { t.title = v }
        if let v = fields.details { t.details = v }
        if let v = fields.status { t.status = v.rawValue }
        if let v = fields.orderKey { t.orderKey = v }
        t.updatedAt = WireDate.now()

        let ops = try fetchOps(taskId: id, in: context)
        if let last = ops.last, !last.transmitted, canCoalesce(fields, into: last) {
            var payload = OpPayload.decode(last.payloadJSON)
            payload.merge(fields)
            last.payloadJSON = OpPayload.encode(payload)
        } else {
            try enqueueOp(kind: .update, taskId: id, payload: fields, in: context)
        }
    }

    /// A status step never overwrites a DIFFERENT status queued in the tail
    /// op — it opens a new op, so each op carries at most one column and an
    /// offline multi-step move replays as legal transitions instead of one
    /// skip (INVALID_TRANSITION). Text and same-column reorders merge as ever.
    private static func canCoalesce(_ fields: OpPayload, into last: CDPendingOp) -> Bool {
        guard let newStatus = fields.status,
              let queuedStatus = OpPayload.decode(last.payloadJSON).status
        else { return true }
        return newStatus == queuedStatus
    }

    /// Move to the end of another column: status + orderKey travel as one
    /// atomic position group (design §9 row 7, §10). The workflow gate lives
    /// inside the transaction — the UI's check runs on a debounced snapshot.
    func moveTask(id: String, to status: TaskStatus) async throws {
        try await perform { context in
            guard let t = try Self.fetchTask(id, in: context),
                  TaskStatus(rawValue: t.status)?.canMove(to: status) == true else { return }
            let key = OrderKey.after(try Self.maxOrderKey(in: status, excluding: id, context: context))
            try Self.applyLocalEdit(id: id, OpPayload(status: status, orderKey: key), in: context)
        }
    }

    /// Drag-and-drop placement at an explicit position in a column. A
    /// cross-column drop carries status+orderKey as ONE atomic position group
    /// in a single op (design §9 row 7, §10); a same-column drop is a plain
    /// reorder.
    func placeTask(id: String, in column: TaskStatus, between lower: String?, and upper: String?) async throws {
        try await perform { context in
            guard let t = try Self.fetchTask(id, in: context),
                  TaskStatus(rawValue: t.status)?.canMove(to: column) == true else { return }
            var payload = OpPayload(orderKey: OrderKey.between(lower, upper))
            if TaskStatus(rawValue: t.status) != column { payload.status = column }
            try Self.applyLocalEdit(id: id, payload, in: context)
        }
    }

    /// Delete. Untransmitted-create cancellation happens locally and never hits
    /// the wire; otherwise untransmitted edits are dropped (moot) and a delete
    /// op is queued behind anything frozen. The row is hidden, not removed, so
    /// frozen ops still have their version base; it is purged on ack.
    /// Returns the task as it was, for undo.
    @discardableResult
    func deleteTask(id: String) async throws -> TaskItem? {
        try await perform { context in
            guard let t = try Self.fetchTask(id, in: context), !t.locallyDeleted else { return nil }
            let snapshot = Self.asItem(t)
            let ops = try Self.fetchOps(taskId: id, in: context)
            let hasUntransmittedCreate = ops.contains { $0.kind == OpKind.create.rawValue && !$0.transmitted }

            if hasUntransmittedCreate {
                ops.forEach(context.delete)
                context.delete(t)
                return snapshot
            }
            for op in ops where !op.transmitted {
                context.delete(op)
            }
            try Self.enqueueOp(kind: .delete, taskId: id, payload: OpPayload(), in: context)
            t.locallyDeleted = true
            // Destructive intent supersedes any pending resolution (delete-wins,
            // design §9): a hidden row's badges are unreachable, so a lingering
            // conflict/failure flag would hold the delete op forever.
            t.conflictJSON = nil
            t.syncFlag = nil
            return snapshot
        }
    }

    /// Clears a terminal-failure flag so held ops for the task flow again.
    /// A locally-born task whose create was terminally rejected has no queued
    /// work left, so Retry re-enqueues the create — the badge can never claim
    /// synced for a task the server never accepted.
    func clearFailure(taskId: String) async throws {
        try await perform { context in
            guard let t = try Self.fetchTask(taskId, in: context) else { return }
            t.syncFlag = nil
            let ops = try Self.fetchOps(taskId: taskId, in: context)
            if t.locallyBorn && ops.isEmpty && !t.locallyDeleted {
                try Self.enqueueOp(kind: .create, taskId: taskId, payload: Self.payloadFromRow(t), in: context)
            }
        }
    }

    // MARK: - Queue access for the sync engine

    func queueSnapshot() async throws -> [PendingOp] {
        try await perform { context in
            try Self.fetchOps(in: context).map(Self.asOp)
        }
    }

    struct SendContext {
        var op: PendingOp
        var baseVersion: Int
        var base: TaskItem?      // last server-acknowledged state (conflict base)
        var locallyBorn: Bool
        var held: Bool           // task is conflicted/failed: do not transmit (design §8)
    }

    /// Marks the op transmitted (unless its task is held) and returns its
    /// frozen state plus the task's current server version — baseVersion is
    /// bound at SEND time (design §8).
    func markTransmitted(opId: Int64) async throws -> SendContext? {
        try await perform { context in
            guard let op = try Self.fetchOp(opId, in: context) else { return nil }
            let task = try Self.fetchTask(op.taskId, in: context)
            // DELETE is version-agnostic and absorbing (§6) — holding it protects
            // nothing and can wedge the queue behind an unreachable badge.
            let held = (task?.conflictJSON != nil || task?.syncFlag != nil) && op.kind != OpKind.delete.rawValue
            if !held { op.transmitted = true }
            return SendContext(
                op: Self.asOp(op),
                baseVersion: Int(task?.version ?? 0),
                base: Self.decodeSnapshot(task?.syncedSnapshot),
                locallyBorn: task?.locallyBorn ?? false,
                held: held
            )
        }
    }

    /// Drops an op with no side effects (e.g. a reorder-only op for a task the
    /// server never learned about — design §8).
    func dropOp(opId: Int64) async throws {
        try await perform { context in
            if let op = try Self.fetchOp(opId, in: context) { context.delete(op) }
        }
    }

    /// A queued op hit 404 for a locally-born task whose create was lost:
    /// rebuild it as a create from the current row (design §8). Later ops
    /// shed their position groups — the row projection already bakes them in,
    /// and replaying a stale step after the birth would walk backwards.
    func convertOpToCreate(opId: Int64) async throws {
        try await perform { context in
            guard let op = try Self.fetchOp(opId, in: context),
                  let t = try Self.fetchTask(op.taskId, in: context) else { return }
            op.kind = OpKind.create.rawValue
            op.transmitted = false
            op.payloadJSON = OpPayload.encode(Self.payloadFromRow(t))
            t.locallyBorn = true
            for later in try Self.fetchOps(taskId: op.taskId, in: context) where later.opId > op.opId {
                var payload = OpPayload.decode(later.payloadJSON)
                guard payload.status != nil || payload.orderKey != nil else { continue }
                payload.status = nil
                payload.orderKey = nil
                if payload.isEmpty {
                    context.delete(later)
                } else {
                    later.payloadJSON = OpPayload.encode(payload)
                }
            }
        }
    }

    /// Success: remove the op, adopt the server row as authority. Visible
    /// fields are only overwritten when no later ops for this task remain
    /// (they carry newer optimistic state).
    func completeOp(opId: Int64, serverRow: TaskItem) async throws {
        try await perform { context in
            try Self.complete(opId: opId, serverRow: serverRow, in: context)
        }
    }

    private static func complete(opId: Int64, serverRow: TaskItem, in context: NSManagedObjectContext) throws {
        let ops = try fetchOps(in: context)
        if let op = ops.first(where: { $0.opId == opId }) { context.delete(op) }
        guard let t = try fetchTask(serverRow.id, in: context) else { return }
        let remaining = ops.filter { $0.taskId == serverRow.id && $0.opId != opId }
        t.version = Int64(serverRow.version)
        t.updatedAt = serverRow.updatedAt
        t.locallyBorn = false
        t.syncedSnapshot = encodeSnapshot(serverRow)
        t.syncFlag = nil
        if remaining.isEmpty && !t.locallyDeleted {
            applyServerFields(serverRow, to: t)
        }
        if t.locallyDeleted && remaining.isEmpty && serverRow.deleted {
            context.delete(t)
        }
    }

    /// Delete op acknowledged (or absorbed): purge the hidden row.
    func completeDelete(opId: Int64, taskId: String) async throws {
        try await perform { context in
            if let op = try Self.fetchOp(opId, in: context) { context.delete(op) }
            let remaining = try Self.fetchOps(taskId: taskId, in: context).filter { $0.opId != opId }
            if let t = try Self.fetchTask(taskId, in: context), t.locallyDeleted, remaining.isEmpty {
                context.delete(t)
            }
        }
    }

    /// Auto-rebase after a disjoint-field 409 (design §9 row 1): new payload,
    /// FRESH mutationId (each rebase is a new logical mutation — §8), adopt the
    /// server row as the new base.
    func rebaseOp(opId: Int64, newPayload: OpPayload, against current: TaskItem) async throws {
        try await perform { context in
            try Self.rebase(opId: opId, newPayload: newPayload, against: current, in: context)
        }
    }

    private static func rebase(opId: Int64, newPayload: OpPayload, against current: TaskItem,
                               in context: NSManagedObjectContext) throws {
        guard let op = try fetchOp(opId, in: context) else { return }
        op.payloadJSON = OpPayload.encode(newPayload)
        op.mutationId = UUID().uuidString.lowercased()
        op.rebaseCount += 1
        op.transmitted = false
        guard let t = try fetchTask(op.taskId, in: context) else { return }
        t.version = Int64(current.version)
        t.syncedSnapshot = encodeSnapshot(current)
        // Re-apply ALL queued payloads over the fresh base — not just this
        // op's — so edits queued behind it stay visible on the board.
        try reprojectVisibleFields(t, base: current, in: context)
    }

    /// A 409 where the server won this op's position group (design §9 rows
    /// 7–8): apply what survives without breaking the workflow chain — if ops
    /// behind need the shed status as their link, it is retained (status
    /// only; the server keeps its orderKey). An empty op is completed away.
    func rebaseAfterPositionLoss(opId: Int64, keeping stripped: OpPayload,
                                 shedStatus: TaskStatus?, against current: TaskItem) async throws {
        try await perform { context in
            guard let op = try Self.fetchOp(opId, in: context) else { return }
            var payload = stripped
            if let link = shedStatus,
               try Self.laterOpsNeedLink(after: opId, taskId: op.taskId,
                                         base: current.status, link: link, in: context) {
                payload.status = link
            }
            if payload.isEmpty {
                try Self.complete(opId: opId, serverRow: current, in: context)
            } else if op.rebaseCount >= 3 {
                // Give up on this op (mirrors the engine's rebase cap), but
                // leave the held queue unable to replay a skip.
                let taskId = op.taskId
                context.delete(op)
                guard let t = try Self.fetchTask(taskId, in: context) else { return }
                t.syncFlag = "Repeated conflicts — edit again to retry"
                t.version = Int64(current.version)
                t.syncedSnapshot = Self.encodeSnapshot(current)
                try Self.stripIllegalSteps(taskId: taskId, base: current.status, in: context)
                try Self.reprojectVisibleFields(t, base: current, in: context)
            } else {
                try Self.rebase(opId: opId, newPayload: payload, against: current, in: context)
            }
        }
    }

    /// Same-field conflict (design §9 row 2): only the collided text goes to
    /// the user; the op's disjoint remainder survives as a rebased op (text
    /// auto-merges per row 1; a lost position sheds its orderKey but keeps
    /// the status when queued steps behind need it as their chain link). The
    /// server row becomes the base; the user's text stays visible.
    func recordConflict(opId: Int64, mine: OpPayload, theirs: TaskItem,
                        fields: [String], positionLost: Bool) async throws {
        try await perform { context in
            var conflicted = OpPayload()
            var remainder = mine
            if fields.contains("title") { conflicted.title = mine.title; remainder.title = nil }
            if fields.contains("details") { conflicted.details = mine.details; remainder.details = nil }
            if positionLost {
                let link = remainder.status
                remainder.status = nil
                remainder.orderKey = nil
                if let link, let op = try Self.fetchOp(opId, in: context),
                   try Self.laterOpsNeedLink(after: opId, taskId: op.taskId,
                                             base: theirs.status, link: link, in: context) {
                    remainder.status = link
                }
            }
            if let op = try Self.fetchOp(opId, in: context) {
                if remainder.isEmpty {
                    context.delete(op)
                } else {
                    op.payloadJSON = OpPayload.encode(remainder)
                    op.mutationId = UUID().uuidString.lowercased()
                    op.rebaseCount += 1
                    op.transmitted = false
                }
            }
            guard let t = try Self.fetchTask(theirs.id, in: context) else { return }
            t.conflictJSON = ConflictRecord.encode(ConflictRecord(mine: conflicted, theirs: theirs, fields: fields))
            t.version = Int64(theirs.version)
            t.syncedSnapshot = Self.encodeSnapshot(theirs)
        }
    }

    /// One transaction: clearing the conflict and enqueueing the kept payload
    /// must be atomic — a crash between them would silently drop the user's
    /// "keep mine" choice (no conflict + no op = next pull adopts the server).
    func resolveConflictKeepMine(taskId: String) async throws {
        try await perform { context in
            guard let t = try Self.fetchTask(taskId, in: context) else { return }
            let record = ConflictRecord.decode(t.conflictJSON)
            t.conflictJSON = nil
            guard var mine = record?.mine else { return }
            // The record holds only the conflicted text (the disjoint rest
            // stayed queued). Any field a queued op already sets is NEWER than
            // the conflicted payload — replaying the old value over it would
            // destroy the user's latest text. Keep only what nothing supersedes.
            for op in try Self.fetchOps(taskId: taskId, in: context) {
                let newer = OpPayload.decode(op.payloadJSON)
                if newer.title != nil { mine.title = nil }
                if newer.details != nil { mine.details = nil }
            }
            guard !mine.isEmpty else { return }
            try Self.applyLocalEdit(id: taskId, mine, in: context)
        }
    }

    func resolveConflictTakeTheirs(taskId: String) async throws {
        try await perform { context in
            guard let t = try Self.fetchTask(taskId, in: context) else { return }
            let record = ConflictRecord.decode(t.conflictJSON)
            t.conflictJSON = nil
            if let theirs = record?.theirs, !t.locallyDeleted {
                t.syncedSnapshot = Self.encodeSnapshot(theirs)
                // Edits queued while the sheet was open are newer than either
                // side — keep them visible on top of the adopted server base.
                try Self.reprojectVisibleFields(t, base: theirs, in: context)
            }
        }
    }

    /// Delete-wins (design §9 rows 3/10): the task was deleted remotely — drop
    /// everything local for it. Returns the last local state for the notice /
    /// restore-as-new affordance.
    @discardableResult
    func taskDeletedRemotely(taskId: String) async throws -> TaskItem? {
        try await perform { context in
            let snapshot = try Self.fetchTask(taskId, in: context).map(Self.asItem)
            try Self.fetchOps(taskId: taskId, in: context).forEach(context.delete)
            if let t = try Self.fetchTask(taskId, in: context) { context.delete(t) }
            return snapshot
        }
    }

    /// Terminal failure (400/404 that cannot be recovered): drop the op, flag
    /// the task, hold its remaining ops (design §8). The optimistic overlay
    /// rolls back to the synced snapshot in the SAME transaction (the network
    /// refresh is a freshness bonus, never load-bearing), and held ops are
    /// stripped of any step the drop made illegal.
    func failOpTerminal(opId: Int64, message: String) async throws {
        try await perform { context in
            guard let op = try Self.fetchOp(opId, in: context) else { return }
            let taskId = op.taskId
            context.delete(op)
            guard let t = try Self.fetchTask(taskId, in: context) else { return }
            t.syncFlag = message
            if let base = Self.decodeSnapshot(t.syncedSnapshot) {
                try Self.stripIllegalSteps(taskId: taskId, base: base.status, in: context)
                try Self.reprojectVisibleFields(t, base: base, in: context)
            }
        }
    }

    /// Refresh one task from the server after a terminal failure. Deliberately
    /// NOT guarded by `row.version > local.version`: after a rejected op the
    /// versions are EQUAL yet the stale optimistic fields must be overwritten.
    func applyServerRow(_ row: TaskItem) async throws {
        try await perform { context in
            guard let t = try Self.fetchTask(row.id, in: context) else { return }
            let ops = try Self.fetchOps(taskId: row.id, in: context)
            t.version = Int64(row.version)
            t.syncedSnapshot = Self.encodeSnapshot(row)
            if ops.isEmpty && !t.locallyDeleted && !row.deleted {
                Self.applyServerFields(row, to: t)
            }
        }
    }

    // MARK: - Pull application (design §8)

    struct PullOutcome {
        var deletedRemotely: [TaskItem] = []
    }

    /// Applies a delta atomically with the cursor. Rows for tasks with queued
    /// local ops are skipped — the push step adjudicates them (§8). Upserts are
    /// guarded by `incoming.version > local.version` so re-applying after a
    /// crash is a no-op.
    func applyPull(rows: [TaskItem], cursor: Int, boardEpoch: String) async throws -> PullOutcome {
        try await perform { context in
            var outcome = PullOutcome()
            for row in rows {
                let ops = try Self.fetchOps(taskId: row.id, in: context)
                let existing = try Self.fetchTask(row.id, in: context)
                if let existing, existing.conflictJSON != nil, ops.isEmpty {
                    // No queued op will re-deliver this delta via a 409, so keep
                    // the open conflict's server side current instead of losing it.
                    if row.deleted {
                        outcome.deletedRemotely.append(Self.asItem(existing))
                        context.delete(existing) // delete wins over the open conflict (§9 row 3)
                    } else if row.version > Int(existing.version) {
                        if var record = ConflictRecord.decode(existing.conflictJSON) {
                            record.theirs = row
                            existing.conflictJSON = ConflictRecord.encode(record)
                        }
                        existing.version = Int64(row.version)
                        existing.syncedSnapshot = Self.encodeSnapshot(row)
                    }
                    continue
                }
                if !ops.isEmpty {
                    continue // push adjudicates
                }
                if row.deleted {
                    if let existing {
                        outcome.deletedRemotely.append(Self.asItem(existing))
                        context.delete(existing)
                    }
                    continue
                }
                if let existing {
                    if row.version > Int(existing.version) {
                        Self.applyServerFields(row, to: existing)
                        existing.syncedSnapshot = Self.encodeSnapshot(row)
                        existing.locallyBorn = false
                        existing.syncFlag = nil
                    }
                } else {
                    Self.insertTask(from: row, in: context)
                }
            }
            let m = try Self.meta(in: context)
            m.cursor = Int64(cursor)
            m.boardEpoch = boardEpoch
            return outcome
        }
    }

    struct EpochResetOutcome {
        var droppedOps: Int = 0
        var keptLocalTasks: Int = 0
    }

    /// The epoch rule (design §8, mandatory): server was reset/replaced under
    /// us. Keep locally-born tasks with pending creates (re-pushed as creates),
    /// drop every other pending op (their basis is gone), replace the synced
    /// snapshot wholesale, adopt the new epoch + cursor.
    func applyEpochReset(snapshot rows: [TaskItem], cursor: Int, boardEpoch: String) async throws -> EpochResetOutcome {
        try await perform { context in
            var outcome = EpochResetOutcome()
            let allOps = try Self.fetchOps(in: context)
            let allTasksReq = NSFetchRequest<CDTask>(entityName: "CDTask")
            let allTasks = try context.fetch(allTasksReq)

            var keepTaskIds = Set<String>()
            for t in allTasks where t.locallyBorn {
                let ops = allOps.filter { $0.taskId == t.id }
                if ops.contains(where: { $0.kind == OpKind.create.rawValue }) {
                    keepTaskIds.insert(t.id)
                }
            }
            for op in allOps where !keepTaskIds.contains(op.taskId) {
                context.delete(op)
                outcome.droppedOps += 1
            }
            for t in allTasks where !keepTaskIds.contains(t.id) {
                context.delete(t)
            }
            outcome.keptLocalTasks = keepTaskIds.count

            for row in rows where !row.deleted {
                Self.insertTask(from: row, in: context)
            }

            let m = try Self.meta(in: context)
            m.cursor = Int64(cursor)
            m.boardEpoch = boardEpoch
            return outcome
        }
    }
}
