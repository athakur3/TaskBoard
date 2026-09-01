import SwiftUI

/// The one-line answer to "did my changes sync?", shown under the board title.
@MainActor
struct SyncStatusLine: View {
    let status: SyncStatusCenter

    var body: some View {
        HStack(spacing: 6) {
            switch status.connectivity {
            case .offline:
                Image(systemName: "wifi.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                Text("Offline — changes saved locally")
                    .foregroundStyle(Theme.amber)
                    .fontWeight(.semibold)
            case .online where status.isSyncing, .unknown where status.isSyncing:
                ProgressView().controlSize(.mini).tint(Theme.blue)
                Text(pendingSuffix.isEmpty ? "Syncing…" : "Syncing… \(pendingSuffix)")
                    .foregroundStyle(Theme.inkSecondary)
            case .online:
                if status.pendingCount > 0 {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                    Text("\(status.pendingCount) change\(status.pendingCount == 1 ? "" : "s") pending")
                        .foregroundStyle(Theme.amber)
                }
                // Caught up and online: the default state says nothing.
            case .unknown:
                Image(systemName: "icloud.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                Text("Not synced yet").foregroundStyle(Theme.inkTertiary)
            }
        }
        .font(.system(size: 13))
    }

    private var pendingSuffix: String {
        status.pendingCount > 0 ? "\(status.pendingCount) to upload" : ""
    }
}

#Preview("States") {
    let offline = SyncStatusCenter(); offline.connectivity = .offline
    let syncing = SyncStatusCenter(); syncing.connectivity = .online; syncing.isSyncing = true; syncing.pendingCount = 2
    let pending = SyncStatusCenter(); pending.connectivity = .online; pending.pendingCount = 3
    let fresh = SyncStatusCenter()
    return VStack(alignment: .leading, spacing: 14) {
        SyncStatusLine(status: offline)
        SyncStatusLine(status: syncing)
        SyncStatusLine(status: pending)
        SyncStatusLine(status: fresh)   // .unknown: "Not synced yet"
    }
    .padding(20)
    .background(Theme.surface)
}
