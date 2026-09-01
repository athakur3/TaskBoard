import SwiftUI

/// Transient event banners (remote deletes with Restore, conflicts, resets) —
/// white shadow cards per the design's banner vocabulary.
@MainActor
struct NoticeBanners: View {
    let status: SyncStatusCenter
    var onRestore: (TaskItem) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(status.notices) { notice in // capped to 3 at post time
                HStack(spacing: 10) {
                    Image(systemName: notice.kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(notice.kind == .warning ? Theme.amber : Theme.blue)
                    Text(notice.message)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let item = notice.restorable {
                        Button("Restore") {
                            onRestore(item)
                            status.dismiss(notice.id)
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.blue)
                        .buttonStyle(.plain)
                    }
                    Button {
                        status.dismiss(notice.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .cardStyle()
            }
        }
        .padding(.horizontal, 20)
    }
}

#Preview("Banners") {
    let status = SyncStatusCenter()
    status.post(SyncNotice(kind: .warning,
                           message: "“Pay invoices” was deleted on another device.",
                           restorable: .sample(title: "Pay invoices")))
    status.post(SyncNotice(message: "Deleted “Old draft”.", restorable: .sample(title: "Old draft")))
    return NoticeBanners(status: status) { _ in }
        .padding(.vertical, 20)
        .background(Theme.surface)
}
