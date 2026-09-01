import SwiftUI

/// Composition root. Everything is constructed once, here, and injected —
/// no singletons in the data path, so tests can build the same graph with an
/// in-memory store and a mock API. Only what the scene body reads is stored;
/// the rest are init locals, retained by the objects that consume them.
@MainActor
final class Workspace {
    let config: NetworkConfig
    let engine: SyncEngine
    let board: Board

    init() {
        config = NetworkConfig()
        let store = LocalStore()
        let api = URLSessionAPIClient(config: config)
        let status = SyncStatusCenter()
        engine = SyncEngine(store: store, api: api, status: status)
        board = Board(store: store, engine: engine, status: status)
    }
}

@main
struct TaskBoardApp: App {   // App is @MainActor at the protocol level; no annotation needed
    @State private var workspace = Workspace()
    @Environment(\.scenePhase) private var scenePhase

    /// The test host must stay inert or every test run syncs the real store
    /// against the real server. Detected via environment (set at spawn) — the
    /// test bundle injects after launch, so a class check evaluates too early.
    private var isTestHost: Bool {
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
    }

    var body: some Scene {
        WindowGroup {
            if isTestHost {
                Color.clear
            } else {
                BoardView(
                    board: workspace.board,
                    config: workspace.config
                )
                .tint(Theme.blue)
                .task {
                    await workspace.engine.start()
                    await workspace.engine.kick(userInitiated: true)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await workspace.engine.kick(userInitiated: true) }
                    }
                }
            }
        }
    }
}
