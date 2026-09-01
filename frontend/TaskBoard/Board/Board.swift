import Foundation
import Observation

/// The board's @Observable app model (MV — no ViewModels): views read it
/// directly; writes go optimistically to the LocalStore, then kick the engine.
@MainActor
@Observable
final class Board {
    private let store: LocalStore
    private let engine: SyncEngine
    let status: SyncStatusCenter

    var tasks: [BoardTask] = []
    var searchText = ""
    var hasLoaded = false

    /// Every modal surface over the board. `id` drives `.sheet(item:)`:
    /// same id = update in place, new id = dismiss + re-present.
    enum Presentation: Identifiable, Equatable {
        case create
        case edit(TaskItem)
        case conflict(ConflictRecord, taskId: String)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let task): return task.id
            case .conflict(_, let taskId): return "conflict-" + taskId
            }
        }
    }

    /// The one modal slot; lives on the model so domain events (an arriving
    /// conflict) can drive navigation.
    var presenting: Presentation?

    /// The most recent move made on THIS device, driving the view's feedback.
    /// Sync-applied moves never set it; cleared ~2s later so feedback fades.
    /// Optimistic: if the store's transactional gate refuses the racing write,
    /// the reload reverts the card — the queue itself never takes a skip.
    struct MoveFeedback: Equatable {
        let taskId: String
        let from: TaskStatus
        let to: TaskStatus
        let seq: Int
    }

    private(set) var lastMove: MoveFeedback?
    private var moveSeq = 0
    private var moveFadeTask: Task<Void, Never>?

    private func noteMove(id: String, from: TaskStatus, to: TaskStatus) {
        guard from != to else { return } // reorders within a column stay quiet
        moveSeq += 1
        lastMove = MoveFeedback(taskId: id, from: from, to: to, seq: moveSeq)
        moveFadeTask?.cancel()
        moveFadeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.lastMove = nil
        }
    }

    private var observer: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?

    init(store: LocalStore, engine: SyncEngine, status: SyncStatusCenter) {
        self.store = store
        self.engine = engine
        self.status = status
        observer = NotificationCenter.default.addObserver(forName: .localStoreDidChange, object: nil, queue: nil) { [weak self] _ in
            guard let vm = self else { return }
            Task { @MainActor in vm.scheduleReload() }
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000) // coalesce bursts
            guard !Task.isCancelled else { return } // `try?` ate the CancellationError
            await self?.reload()
        }
    }

    func reload() async {
        if let board = try? await store.board() {
            tasks = board
            hasLoaded = true
            status.pendingCount = (try? await store.pendingOpCount()) ?? 0
        }
    }

    func section(_ column: TaskStatus) -> [BoardTask] {
        let inColumn = tasks.filter { $0.item.status == column }
        guard !searchText.isEmpty else { return inColumn }
        let query = searchText.lowercased()
        return inColumn.filter {
            $0.item.title.lowercased().contains(query) || $0.item.details.lowercased().contains(query)
        }
    }

    var isBoardEmpty: Bool { hasLoaded && tasks.isEmpty && searchText.isEmpty }

    // MARK: - Intents (every one works fully offline)

    /// New tasks are born in To Do; `status` exists for restore, which
    /// re-creates a task in the column it died in (an undo, not a transition).
    func createTask(title: String, details: String, status: TaskStatus = .todo) {
        Task {
            _ = try? await store.createTask(title: title, details: details, status: status)
            await engine.kick(userInitiated: true)
        }
    }

    /// Content only — column moves are their own intent (`move`).
    func saveEdits(id: String, title: String, details: String) {
        Task {
            guard let current = try? await store.task(id: id) else { return }
            var payload = OpPayload()
            if title != current.title { payload.title = title }
            if details != current.details { payload.details = details }
            if !payload.isEmpty {
                try? await store.updateTask(id: id, payload)
            }
            await engine.kick(userInitiated: true)
        }
    }

    /// Synchronous optimistic mutation: the tap animates in the same frame;
    /// the store write follows and the debounced reload reconciles to an
    /// identical layout. Array position mirrors what the store will compute,
    /// which is what makes the reconcile a visual no-op.
    private func applyOptimisticMove(id: String, to column: TaskStatus, before targetId: String? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var task = tasks.remove(at: index)
        task.item.status = column
        if task.badge == .synced { task.badge = .pending } // an op is about to queue
        if let targetId, let target = tasks.firstIndex(where: { $0.id == targetId }) {
            tasks.insert(task, at: target)
        } else {
            tasks.append(task) // section() filters by status, so array-end = column-end
        }
    }

    func move(id: String, to column: TaskStatus) {
        guard let task = tasks.first(where: { $0.id == id }),
              task.item.status.canMove(to: column) else { return }
        noteMove(id: id, from: task.item.status, to: column)
        applyOptimisticMove(id: id, to: column)
        Task {
            try? await store.moveTask(id: id, to: column)
            await engine.kick(userInitiated: true)
        }
    }

    /// Card dropped onto another card: insert before it. Neighbors come from
    /// the *unfiltered* column so the fractional key is minted against real
    /// adjacency (design §9 row 7, §10). Returns false to refuse an illegal
    /// drop (the card animates back).
    func dropCard(_ ids: [String], before targetId: String, in column: TaskStatus) -> Bool {
        guard let draggedId = ids.first, draggedId != targetId,
              let dragged = tasks.first(where: { $0.id == draggedId }),
              dragged.item.status.canMove(to: column) else { return false }
        let items = tasks.filter { $0.item.status == column && $0.id != draggedId }
        guard let index = items.firstIndex(where: { $0.id == targetId }) else { return false }
        let lower = index > 0 ? items[index - 1].item.orderKey : nil
        let upper = items[index].item.orderKey
        noteMove(id: draggedId, from: dragged.item.status, to: column)
        applyOptimisticMove(id: draggedId, to: column, before: targetId)
        place(draggedId, in: column, between: lower, and: upper)
        return true
    }

    /// Card dropped on a column's empty area: append at the end.
    func dropAtEnd(_ ids: [String], in column: TaskStatus) -> Bool {
        guard let draggedId = ids.first,
              let dragged = tasks.first(where: { $0.id == draggedId }),
              dragged.item.status.canMove(to: column) else { return false }
        let items = tasks.filter { $0.item.status == column && $0.id != draggedId }
        noteMove(id: draggedId, from: dragged.item.status, to: column)
        applyOptimisticMove(id: draggedId, to: column)
        place(draggedId, in: column, between: items.last?.item.orderKey, and: nil)
        return true
    }

    private func place(_ id: String, in column: TaskStatus, between lower: String?, and upper: String?) {
        Task {
            try? await store.placeTask(id: id, in: column, between: lower, and: upper)
            await engine.kick(userInitiated: true)
        }
    }

    func delete(id: String) {
        tasks.removeAll { $0.id == id } // optimistic: the card leaves this frame
        Task {
            if let removed = try? await store.deleteTask(id: id) {
                status.post(SyncNotice(message: "Deleted “\(removed.title)”.", restorable: removed))
            }
            await engine.kick(userInitiated: true)
        }
    }

    /// Restore = create under a NEW UUID (tombstones are permanent; §9 row 3).
    func restore(_ item: TaskItem) {
        createTask(title: item.title, details: item.details, status: item.status)
    }

    func openConflict(taskId: String) {
        Task {
            if let record = try? await store.conflict(taskId: taskId) {
                guard presenting == nil else { return } // conflicts open only from an idle board
                presenting = .conflict(record, taskId: taskId)
            }
        }
    }

    func resolveConflict(taskId: String, keepMine: Bool) {
        Task {
            if keepMine {
                try? await store.resolveConflictKeepMine(taskId: taskId)
            } else {
                try? await store.resolveConflictTakeTheirs(taskId: taskId)
            }
            await engine.kick(userInitiated: true)
        }
    }

    func retryFailed(taskId: String) {
        Task {
            try? await store.clearFailure(taskId: taskId)
            await engine.kick(userInitiated: true)
        }
    }

    /// Awaitable so pull-to-refresh can hold its spinner until the full
    /// push+pull cycle finishes. Bypasses backoff (user-initiated).
    func sync() async {
        await engine.kick(userInitiated: true)
    }
}
