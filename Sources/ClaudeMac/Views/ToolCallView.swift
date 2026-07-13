import SwiftUI

struct ToolCallView: View {
    let activity: ToolActivity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                details
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        .padding(.leading, 38)
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
                    .font(.callout.weight(.semibold))
                Text(activity.headline)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                statusIndicator
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
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
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        } else {
            Image(systemName: "checkmark").foregroundStyle(.green.opacity(0.8)).font(.caption)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            labeledBlock("Entrée", activity.input.pretty())
            if let result = activity.resultText, !result.isEmpty {
                labeledBlock(activity.isError ? "Erreur" : "Résultat", result)
            }
        }
        .padding(12)
    }

    private func labeledBlock(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
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
