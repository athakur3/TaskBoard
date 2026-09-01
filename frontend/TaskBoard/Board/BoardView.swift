import SwiftUI

/// The board: floating cards, chip-row column headers, per-card workflow
/// step chips; drag & drop covers the same moves spatially.
@MainActor
struct BoardView: View {
    @Bindable var board: Board
    @Bindable var config: NetworkConfig

    @State private var retryTaskId: String?
    /// Two-way bound to the board's scroll position (chips ↔ swipes).
    @State private var focusedColumn: TaskStatus? = .todo
    /// Together these light up only the LEGAL drop targets while dragging.
    @State private var targetedColumn: TaskStatus?
    @State private var draggingStatus: TaskStatus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Theme.surface.ignoresSafeArea()

            VStack(spacing: 14) {
                header
                searchField
                NoticeBanners(status: board.status) { board.restore($0) }
                if board.isBoardEmpty {
                    emptyState
                } else {
                    boardArea
                }
            }
            .padding(.top, 8)

            newTaskButton
        }
        .preferredColorScheme(.light)
        .sheet(item: $board.presenting) { presentation in
            // Switch over the closure's parameter, never board.presenting —
            // the property goes nil during the dismiss animation.
            switch presentation {
            case .create:
                TaskDetailView(mode: .create) { title, details in
                    board.createTask(title: title, details: details)
                }
            case .edit(let task):
                TaskDetailView(mode: .edit(task)) { title, details in
                    board.saveEdits(id: task.id, title: title, details: details)
                }
            case .conflict(let record, taskId: let taskId):
                ConflictView(record: record) { keepMine in
                    board.resolveConflict(taskId: taskId, keepMine: keepMine)
                }
            }
        }
        // An alert, not a Presentation case: it confirms an action in place.
        .alert("Retry sync for this task?", isPresented: Binding(
            get: { retryTaskId != nil },
            set: { if !$0 { retryTaskId = nil } }
        )) {
            Button("Retry") {
                if let id = retryTaskId { board.retryFailed(taskId: id) }
                retryTaskId = nil
            }
            Button("Cancel", role: .cancel) { retryTaskId = nil }
        } message: {
            Text(retryMessage)
        }
        .sensoryFeedback(.success, trigger: board.lastMove?.seq) { _, _ in
            board.lastMove?.to == .done
        }
        .sensoryFeedback(.impact(weight: .light), trigger: board.lastMove?.seq) { _, _ in
            board.lastMove.map { $0.to != .done } ?? false
        }
        .onChange(of: board.lastMove) { _, move in
            if let move {
                AccessibilityNotification.Announcement("Moved to \(move.to.displayName)").post()
            }
        }
        .task { await board.reload() }
    }

    /// The failed badge carries the server's own reason — show it.
    private var retryMessage: String {
        var lines = ["The last change to this task could not be synced."]
        if let id = retryTaskId,
           let task = board.tasks.first(where: { $0.id == id }),
           case .failed(let reason) = task.badge {
            lines = ["The server said: “\(reason)”."]
        }
        lines.append("That change was rolled back — any other queued changes for this task are on hold until you retry.")
        return lines.joined(separator: " ")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Task Board")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                SyncStatusLine(status: board.status)
            }
            Spacer()
            offlineToggle
        }
        .padding(.horizontal, 20)
    }

    /// Cuts requests off at the client, before the socket — airplane mode on
    /// demand. Flipping it kicks a sync so the status line reacts immediately.
    private var offlineToggle: some View {
        HStack(spacing: 8) {
            Text("Offline")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(config.simulateOffline ? Theme.amberDeep : Theme.inkTertiary)
            Toggle("", isOn: $config.simulateOffline)
                .labelsHidden()
                .tint(Theme.amber)
                .onChange(of: config.simulateOffline) { _, _ in Task { await board.sync() } }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(config.simulateOffline ? Theme.amberTint : Theme.card, in: Capsule())
        .shadow(color: Theme.cardShadow, radius: 6, y: 2)
        .accessibilityLabel("Simulate offline")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
            TextField("Search tasks", text: $board.searchText)
                .font(.system(size: 16))
                .foregroundStyle(Theme.ink)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Theme.card, in: Capsule())
        .shadow(color: Theme.cardShadow, radius: 6, y: 2)
        .padding(.horizontal, 20)
    }

    // MARK: - Board

    /// The board's structural fingerprint: which cards exist, in what order,
    /// in which column. Content edits and sync metadata don't change it.
    private var boardLayout: [String] {
        board.tasks.map { $0.id + $0.item.status.rawValue }
    }

    private var boardArea: some View {
        VStack(spacing: 16) {
            columnChips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(TaskStatus.allCases) { column in
                        columnView(column)
                            .id(column)
                    }
                }
                .scrollTargetLayout()
                // Structural changes only — keying on the whole array would
                // re-animate on every sync echo (version/timestamp bumps).
                .animation(.snappy(duration: 0.3), value: boardLayout)
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            // Center-anchored: a leading anchor lies at full right-scroll,
            // where the last column can never reach the leading edge.
            .scrollPosition(id: $focusedColumn, anchor: .center)
        }
    }

    /// The chips ARE the column headers; the columns don't repeat them.
    private var columnChips: some View {
        HStack(spacing: 8) {
            ForEach(TaskStatus.allCases) { column in
                let active = focusedColumn == column
                let count = board.section(column).count
                // A move pulses its destination chip in that column's tint.
                let pulsing = !active && board.lastMove?.to == column
                let tint = Theme.lozenge(for: column)
                Button {
                    withAnimation(.easeOut(duration: 0.25)) {
                        focusedColumn = column
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(column.displayName)
                        Text("\(count)")
                            .foregroundStyle(active ? Color.white.opacity(0.7) : Theme.inkTertiary)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.3), value: count)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(active ? .white : (pulsing ? tint.fg : Theme.inkMid))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(active ? Theme.ink : (pulsing ? tint.bg : Theme.card), in: Capsule())
                    .shadow(color: Theme.cardShadow, radius: 4, y: 2)
                    .animation(.easeOut(duration: 0.3), value: pulsing)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func columnView(_ column: TaskStatus) -> some View {
        let rows = board.section(column)
        // Light up only while a drag hovers AND the workflow allows the drop.
        let washed = targetedColumn == column && draggingStatus.map {
            $0 != column && $0.canMove(to: column)
        } == true
        let tint = Theme.lozenge(for: column)
        return VStack(alignment: .leading, spacing: 12) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(rows) { task in
                        card(task, in: column)
                    }
                    if rows.isEmpty && column != .todo {
                        emptyColumnHint(column)
                    }
                    if column == .todo {
                        addTaskRow
                    }
                }
                .padding(.bottom, 90) // keep the last card clear of the FAB
            }
            .refreshable { await board.sync() } // pull any column = sync now
        }
        .frame(width: 296)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            if washed {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(tint.bg.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(tint.fg.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    )
                    .padding(-8)
            }
        }
        .animation(.easeOut(duration: 0.15), value: washed)
        .dropDestination(for: String.self) { ids, _ in
            defer { draggingStatus = nil }
            return board.dropAtEnd(ids, in: column)
        } isTargeted: { hovering in
            if hovering { targetedColumn = column } else if targetedColumn == column { targetedColumn = nil }
        }
    }

    /// Under To Do only — every task is born there (workflow rule).
    private var addTaskRow: some View {
        Button {
            board.presenting = .create
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                Text("Add a task")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Theme.inkSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.borderStrong, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    /// Visible drop target for an empty column.
    private func emptyColumnHint(_ column: TaskStatus) -> some View {
        Text(column == .done ? "Nothing finished yet" : "Drag a card here")
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.inkTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.border, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            )
    }

    private func card(_ task: BoardTask, in column: TaskStatus) -> some View {
        TaskCardView(task: task,
                     justMoved: board.lastMove?.taskId == task.id,
                     onBadgeTap: { handleBadgeTap(task) },
                     onMove: { target in board.move(id: task.id, to: target) })
            .onTapGesture { board.presenting = .edit(task.item) }
            .contextMenu {
                Button("Edit") { board.presenting = .edit(task.item) }
                Button("Delete", role: .destructive) { board.delete(id: task.id) }
            }
            .draggable(task.item.id) {
                // The preview builder is SwiftUI's only drag-start hook:
                // remember what's dragged so only legal columns light up.
                TaskCardView(task: task, onBadgeTap: {}, onMove: { _ in })
                    .frame(width: 296)
                    .onAppear { draggingStatus = task.item.status }
            }
            .dropDestination(for: String.self) { ids, _ in
                defer { draggingStatus = nil }
                return board.dropCard(ids, before: task.id, in: column)
            } isTargeted: { hovering in
                if hovering { targetedColumn = column } else if targetedColumn == column { targetedColumn = nil }
            }
            .transition(cardTransition(for: task))
    }

    /// Forward moves travel right, back moves left — the same order the
    /// columns sit on screen. Reduce Motion → plain fade.
    private func cardTransition(for task: BoardTask) -> AnyTransition {
        guard !reduceMotion, let move = board.lastMove, move.taskId == task.id else { return .opacity }
        let forward = move.from.forward == move.to
        return .asymmetric(
            insertion: .move(edge: forward ? .leading : .trailing).combined(with: .opacity),
            removal: .move(edge: forward ? .trailing : .leading).combined(with: .opacity)
        )
    }

    private func handleBadgeTap(_ task: BoardTask) {
        switch task.badge {
        case .conflict: board.openConflict(taskId: task.id)
        case .failed: retryTaskId = task.id
        default: break
        }
    }

    // MARK: - Empty state & FAB

    private var emptyState: some View {
        VStack {
            Spacer()
            ContentUnavailableView {
                Label("No tasks yet", systemImage: "checklist")
            } description: {
                Text("Every task starts in To Do and moves one column at a time.\nEverything works offline and syncs when the server is reachable.")
            } actions: {
                Button("New Task") {
                    board.presenting = .create
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 44)
                .background(Theme.blue, in: Capsule())
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var newTaskButton: some View {
        Button {
            board.presenting = .create
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                Text("New Task")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 52)
            .background(Theme.blue, in: Capsule())
            .shadow(color: Theme.blue.opacity(0.35), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .accessibilityLabel("New task")
    }
}

#Preview {
    BoardPreview()
}

/// A live board over an in-memory store, seeded on appear — no server needed.
@MainActor
private struct BoardPreview: View {
    let config: NetworkConfig
    let board: Board
    let store: LocalStore

    init() {
        let config = NetworkConfig()
        let store = LocalStore(inMemory: true)
        let status = SyncStatusCenter()
        let engine = SyncEngine(store: store, api: URLSessionAPIClient(config: config), status: status)
        self.config = config
        self.store = store
        self.board = Board(store: store, engine: engine, status: status)
    }

    var body: some View {
        BoardView(board: board, config: config)
            .task {
                _ = try? await store.createTask(title: "Design offline badges", details: "Pending / synced / failed states per task.", status: .todo)
                _ = try? await store.createTask(title: "Wire up task details screen", details: "Edit title, description and status.", status: .todo)
                _ = try? await store.createTask(title: "Build the sync engine", details: "Push FIFO, then pull the delta.", status: .inProgress)
                _ = try? await store.createTask(title: "Project scaffolding", details: "", status: .done)
            }
    }
}
