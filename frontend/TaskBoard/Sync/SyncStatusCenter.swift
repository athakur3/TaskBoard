import Foundation
import Observation

/// One transient, user-visible sync event (deleted-on-another-device, dropped
/// offline work after a server reset, an unresolved conflict, ...).
struct SyncNotice: Identifiable, Equatable {
    enum Kind { case info, warning }
    let id = UUID()
    var kind: Kind = .info
    var message: String
    /// When set, the notice offers "Restore" — recreating the task under a NEW
    /// UUID (tombstones are permanent; design §9 row 3).
    var restorable: TaskItem?
}

/// Main-actor observable mirror of the sync engine's state, driving the board's
/// status bar and per-task badges (assignment: the user must understand whether
/// their changes have been synchronized).
@MainActor
@Observable
final class SyncStatusCenter {
    enum Connectivity { case unknown, online, offline }

    var isSyncing = false
    var connectivity: Connectivity = .unknown
    var pendingCount = 0
    var notices: [SyncNotice] = []

    func post(_ notice: SyncNotice) {
        notices.append(notice)
        // Only the newest three render; drop older ones rather than strand
        // them (and their Restore buttons) invisibly forever.
        if notices.count > 3 { notices.removeFirst(notices.count - 3) }
    }

    func dismiss(_ id: UUID) {
        notices.removeAll { $0.id == id }
    }
}
