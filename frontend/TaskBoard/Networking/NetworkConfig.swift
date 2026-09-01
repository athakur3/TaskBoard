import Foundation
import Observation

/// The network client's knobs. `simulateOffline` persists across relaunches;
/// the URL is fixed (no UI changes it, so a saved value would be a trap).
/// `@unchecked Sendable`: the one mutable bit is lock-guarded — written by
/// the MainActor toggle, read from the engine inside the API client.
@Observable
final class NetworkConfig: @unchecked Sendable {
    private static let simulateOfflineKey = "debug.simulateOffline"

    let baseURL = "http://localhost:4000"

    private let lock = NSLock()
    private var _simulateOffline: Bool

    var simulateOffline: Bool {
        get { lock.withLock { _simulateOffline } }
        set {
            lock.withLock { _simulateOffline = newValue }
            UserDefaults.standard.set(newValue, forKey: Self.simulateOfflineKey)
        }
    }

    init() {
        _simulateOffline = UserDefaults.standard.bool(forKey: Self.simulateOfflineKey)
    }
}
