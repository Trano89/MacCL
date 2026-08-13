import SwiftUI

struct ToolCallView: View {
    let activity: ToolActivity
    var onOpenAgent: ((String) -> Void)? = nil
    /// Transcript cards sit indented under the message they belong to; the same
    /// card inside the agents panel has no message above it, so it starts flush.
    var indent: CGFloat = 38
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // The link into the agents panel: every Task card carries one, so a
            // sub-agent is always one click from its instructions and progress.
            if activity.name == "Task", let onOpenAgent {
                Divider().padding(.horizontal, 12)
                Button {
                    onOpenAgent(activity.toolUseId)
                } label: {
                    Label(L10n.t("agent_open"), systemImage: "sidebar.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            if expanded {
                details
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.hairline))
        .padding(.leading, indent)
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 16)
                Text(activity.name)
                    .font(.body.weight(.semibold))
                Text(activity.headline)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                statusIndicator
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var statusIndicator: some View {
        if activity.isRunning {
            ProgressView().controlSize(.small)
        } else if activity.isError {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark").foregroundStyle(.green.opacity(0.8))
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            labeledBlock(L10n.t("input"), activity.input.pretty())
            if let result = activity.resultText, !result.isEmpty {
                labeledBlock(activity.isError ? L10n.t("error") : L10n.t("result"), result)
            }
        }
        .padding(12)
    }

    private func labeledBlock(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.body.weight(.semibold))
                .foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
        }
    }

    private var icon: String {
        switch activity.name {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "Write", "NotebookEdit": return "square.and.pencil"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder"
        case "WebFetch", "WebSearch": return "globe"
        case "Task": return "person.2"
        case "TodoWrite": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }
}
