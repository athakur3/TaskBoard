import SwiftUI

/// Per-card sync chip. Synced is the default state and says nothing — the
/// chip speaks only when something needs attention.
struct SyncChip: View {
    let badge: TaskSyncBadge

    var body: some View {
        switch badge {
        case .synced:
            EmptyView()
        case .pending:
            chip("icloud.and.arrow.up", "Pending", Theme.amber)
        case .failed:
            chip("exclamationmark.icloud", "Failed", Theme.red)
        case .conflict:
            chip("exclamationmark.triangle.fill", "Conflict", Theme.red)
        }
    }

    private func chip(_ icon: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(label).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(color)
    }
}

/// A board card: title, one-line description, sync/time footer, and the
/// task's legal workflow steps as one-tap chips.
@MainActor
struct TaskCardView: View {
    let task: BoardTask
    /// Briefly true after a local move: the card wears a fading outline in
    /// its new column's color so the arrival is spottable.
    var justMoved = false
    var onBadgeTap: () -> Void
    var onMove: (TaskStatus) -> Void

    private var arrivalColor: Color { Theme.lozenge(for: task.item.status).fg }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(task.item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Text(updatedTime)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkTertiary)
            }
            if !task.item.details.isEmpty {
                Text(task.item.details)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            // Sync state gets its own row only when it has something to say.
            switch task.badge {
            case .failed, .conflict:
                Button(action: onBadgeTap) { SyncChip(badge: task.badge) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(task.badge == .conflict ? "Conflict — tap to resolve" : "Sync failed — tap to retry")
            default:
                SyncChip(badge: task.badge)
            }
            stepRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .overlay {
            if justMoved {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(arrivalColor.opacity(0.5), lineWidth: 1.5)
            }
        }
        .shadow(color: justMoved ? arrivalColor.opacity(0.22) : .clear, radius: 8)
        .animation(.easeOut(duration: 0.45), value: justMoved)
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    /// At most one step back (left, quiet) and one forward (right, tinted
    /// like its destination) — matching the columns' on-screen order.
    private var stepRow: some View {
        HStack {
            if let back = task.item.status.backward {
                StepChip(step: .back(to: back)) { onMove(back) }
            }
            Spacer(minLength: 4)
            if let ahead = task.item.status.forward {
                StepChip(step: .forward(to: ahead)) { onMove(ahead) }
            }
        }
    }

    private var updatedTime: String {
        guard let date = WireDate.parse(task.item.updatedAt) else { return "" }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// One legal workflow move as a capsule button.
struct StepChip: View {
    enum Step {
        case forward(to: TaskStatus)
        case back(to: TaskStatus)
    }

    let step: Step
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if case .back = step {
                    Image(systemName: icon).font(.system(size: 11, weight: .bold))
                }
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                if case .forward = step {
                    Image(systemName: icon).font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(background, in: Capsule())
        }
        .buttonStyle(PressedScaleStyle())
        .accessibilityLabel(accessibility)
    }

    /// Verbs forward, destinations back.
    private var label: String {
        switch step {
        case .forward(to: .done): return "Complete"
        case .forward: return "Start"
        case .back(to: .inProgress): return "Reopen"
        case .back(let to): return to.displayName
        }
    }

    private var icon: String {
        switch step {
        case .forward(to: .done): return "checkmark"
        case .forward: return "chevron.right"
        case .back(to: .inProgress): return "arrow.uturn.backward"
        case .back: return "chevron.left"
        }
    }

    private var foreground: Color {
        switch step {
        case .forward(let to): return Theme.lozenge(for: to).fg
        case .back: return Theme.inkSecondary
        }
    }

    private var background: Color {
        switch step {
        case .forward(let to): return Theme.lozenge(for: to).bg
        case .back: return Theme.surface
        }
    }

    private var accessibility: String {
        switch step {
        case .forward(let to), .back(let to): return "Move to \(to.displayName)"
        }
    }
}

#Preview("Badge states") {
    VStack(spacing: 12) {
        TaskCardView(task: BoardTask(item: .sample(), badge: .synced), onBadgeTap: {}, onMove: { _ in })
        TaskCardView(task: BoardTask(item: .sample(title: "Queued while offline", status: .inProgress), badge: .pending), onBadgeTap: {}, onMove: { _ in })
        TaskCardView(task: BoardTask(item: .sample(title: "Server said no", status: .done), badge: .failed("title too long")), onBadgeTap: {}, onMove: { _ in })
        TaskCardView(task: BoardTask(item: .sample(title: "Edited on two devices"), badge: .conflict), onBadgeTap: {}, onMove: { _ in })
    }
    .padding(20)
    .frame(width: 352)
    .background(Theme.surface)
}
