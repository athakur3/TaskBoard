import SwiftUI

/// Create/edit sheet for a task's CONTENT — title and description. Column
/// moves live on the board (step chips, drag & drop): a new task is always
/// born in To Do, and an edit never smuggles a transition.
@MainActor
struct TaskDetailView: View {
    enum Mode {
        case create
        case edit(TaskItem)
    }

    let mode: Mode
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.blue)
                Spacer()
                Text(isEditing ? "Edit Task" : "New Task")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button {
                    onSave(trimmedTitle, details)
                    dismiss()
                } label: {
                    Text(isEditing ? "Save" : "Add")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(trimmedTitle.isEmpty ? Theme.inkTertiary : Theme.blue, in: Capsule())
                }
                .disabled(trimmedTitle.isEmpty)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Title")
                        TextField("What needs doing?", text: $title, axis: .vertical)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .padding(14)
                            .cardStyle()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Description")
                        TextField("Details (optional)", text: $details, axis: .vertical)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(4...10)
                            .padding(14)
                            .cardStyle()
                    }

                    if case .create = mode {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.inkTertiary)
                            Text("New tasks start in To Do and move one column at a time.")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.inkTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 4)
                    }

                    if case .edit(let task) = mode {
                        HStack(spacing: 8) {
                            SectionLabel(text: "Column")
                            let lozenge = Theme.lozenge(for: task.status)
                            Lozenge(text: task.status.displayName, bg: lozenge.bg, fg: lozenge.fg)
                            Spacer()
                        }
                    }

                    if case .edit(let task) = mode {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: "Sync")
                            VStack(spacing: 0) {
                                syncRow("Created", value: WireDate.displayString(task.createdAt))
                                Divider().overlay(Theme.divider)
                                syncRow("Updated", value: WireDate.displayString(task.updatedAt))
                                Divider().overlay(Theme.divider)
                                syncRow("Server version", value: task.version == 0 ? "not synced yet" : "\(task.version)")
                                Divider().overlay(Theme.divider)
                                HStack {
                                    Text("Task ID")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Theme.inkMid)
                                    Spacer()
                                    Text(task.id)
                                        .font(.system(size: 12).monospaced())
                                        .foregroundStyle(Theme.inkSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: 180, alignment: .trailing)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 48)
                            }
                            .cardStyle()
                            Text("Changes are saved on this device first and upload when the server is reachable.")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.inkTertiary)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(Theme.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if case .edit(let task) = mode {
                title = task.title
                details = task.details
            }
        }
    }

    private func syncRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Theme.inkMid)
            Spacer()
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }
}

/// Same-field conflict resolution: your version vs the server's, two actions.
/// Conflicting field values are highlighted; everything else merges (§9).
@MainActor
struct ConflictView: View {
    let record: ConflictRecord
    let onResolve: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Sync Conflict")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.amber)
                        Text("This task was edited on another device while your change was waiting to sync. Choose which version to keep.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.amberDeep)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .background(Theme.amberTint, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.amberBorder, lineWidth: 1))

                    mineCard
                    serverCard

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.inkTertiary)
                        Text("Only the highlighted fields conflict — fields edited on just one device merge automatically.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(20)
            }

            VStack(spacing: 10) {
                actionButton("Keep my version", primary: true) { onResolve(true); dismiss() }
                actionButton("Use server version", primary: false) { onResolve(false); dismiss() }
            }
            .padding(20)
        }
        .background(Theme.surface)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var mineCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.blueDark)
                Text("Your version")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.blueDark)
                Spacer()
                Lozenge(text: "This device", bg: Theme.blueTint, fg: Theme.blueDark)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.blueWash)
            Divider().overlay(Theme.divider)
            VStack(alignment: .leading, spacing: 12) {
                if let mineTitle = record.mine.title {
                    fieldValue("Title", mineTitle, highlighted: record.fields.contains("title"))
                }
                if let mineDetails = record.mine.details {
                    fieldValue("Description", mineDetails, highlighted: record.fields.contains("details"))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.blue, lineWidth: 1.5))
        .shadow(color: Theme.blue.opacity(0.12), radius: 4, y: 2)
    }

    private var serverCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "cloud")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.inkMid)
                Text("Server version")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.inkMid)
                Spacer()
                Text("Updated \(WireDate.displayString(record.theirs.updatedAt))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider().overlay(Theme.divider)
            VStack(alignment: .leading, spacing: 12) {
                fieldValue("Title", record.theirs.title, highlighted: record.fields.contains("title"))
                if !record.theirs.details.isEmpty {
                    fieldValue("Description", record.theirs.details, highlighted: record.fields.contains("details"))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
    }

    private func fieldValue(_ label: String, _ value: String, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, highlighted ? 4 : 0)
                .padding(.vertical, highlighted ? 2 : 0)
                .background(highlighted ? Theme.amberTint : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func actionButton(_ label: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(primary ? .white : Theme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(primary ? Theme.blue : Theme.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(primary ? Color.clear : Theme.borderStrong, lineWidth: 1))
                .shadow(color: primary ? Theme.blue.opacity(0.3) : .clear, radius: 6, y: 3)
        }
        .buttonStyle(.plain)
    }
}

#Preview("Create") {
    TaskDetailView(mode: .create) { _, _ in }
}

#Preview("Edit") {
    TaskDetailView(mode: .edit(.sample())) { _, _ in }
}

#Preview("Conflict") {
    ConflictView(record: ConflictRecord(
        mine: OpPayload(title: "Redesign the sync badges"),
        theirs: .sample(title: "Rework status chips", version: 7),
        fields: ["title"]
    )) { _ in }
}
