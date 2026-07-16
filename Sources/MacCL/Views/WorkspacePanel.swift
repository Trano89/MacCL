import SwiftUI

// MARK: - Data model for workspace tree nodes

struct WorkspaceNode: Identifiable, Equatable {
    let id: String
    let kind: Kind        // file / edit / terminal / agent
    let title: String     // short label shown in the row
    var status: NodeStatus = .idle
    var preview: String   // brief result or command text
    var children: [WorkspaceNode] = []

    enum Kind {
        case file, edit, terminal, agent

        var icon: String {
            switch self {
            case .file:     return "doc"
            case .edit:     return "pencil.and.ruler"
            case .terminal: return "terminal"
            case .agent:    return "person.2"
            }
        }

        var iconColor: Color {
            switch self {
            case .file:     return .blue
            case .edit:     return .orange
            case .terminal: return .purple
            case .agent:    return .green
            }
        }
    }

    enum NodeStatus {
        case idle, running, completed, failed

        var dotColor: Color {
            switch self {
            case .idle:       return .gray.opacity(0.4)
            case .running:    return .orange
            case .completed: return .green
            case .failed:    return .red
            }
        }

        var iconSuffix: String {
            switch self {
            case .idle:       return ""
            case .running:    return ".circle.fill"
            case .completed: return ""
            case .failed:    return ""
            }
        }
    }

    static func == (lhs: WorkspaceNode, rhs: WorkspaceNode) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status
    }
}

// MARK: - WorkspacePanel view

struct WorkspacePanelView: View {
    @ObservedObject var monitor: AgentMonitorModel
    let onClose: () -> Void
    @EnvironmentObject var settings: AppSettings

    /// Nodes derived from the agent monitor.
    private var nodes: [WorkspaceNode] {
        var result: [WorkspaceNode] = []

        for agent in monitor.agents {
            let parentNode = WorkspaceNode(
                id: "agent-\(agent.id)",
                kind: .agent,
                title: agent.name,
                status: nodeStatus(from: agent.status),
                preview: agent.description.isEmpty ? "" : agent.description
            )

            // Child nodes for tool activities associated with this agent.
            var children: [WorkspaceNode] = []
            let toolKinds = extractToolActivities(for: agent)
            for ta in toolKinds {
                children.append(WorkspaceNode(
                    id: "child-\(ta.id)-\(ta.name)",
                    kind: ta.kind,
                    title: ta.name,
                    status: ta.status,
                    preview: ta.preview ?? ""
                ))
            }
            var node = parentNode
            node.children = children
            result.append(node)
        }

        return result
    }

    /// Extract tool activities from the agent monitor's task results.
    private func extractToolActivities(for agent: AgentState) -> [(id: String, name: String, kind: WorkspaceNode.Kind, status: WorkspaceNode.NodeStatus, preview: String?)] {
        var results: [(String, String, WorkspaceNode.Kind, WorkspaceNode.NodeStatus, String?)] = []

        // Use the agent's name as a preview of its output.
        if !agent.name.isEmpty && agent.name != agent.description {
            let kind: WorkspaceNode.Kind
            switch agent.status {
            case .running:   kind = .terminal
            case .completed: kind = .edit
            case .failed:    kind = .file
            case .queued:    kind = .agent
            }
            results.append((agent.id, agent.name, kind, nodeStatus(from: agent.status), nil))
        }

        return results
    }

    private func nodeStatus(from status: AgentState.Status) -> WorkspaceNode.NodeStatus {
        switch status {
        case .queued:      return .idle
        case .running:     return .running
        case .completed:  return .completed
        case .failed:      return .failed
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 300, maxWidth: 400)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow.tooltop")
                .foregroundStyle(Theme.accent)
            Text(L10n.t("workspace_panel_title"))
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.t("close"))
        }
        .padding(12)
        .background(Theme.accentSoft.opacity(0.6))
    }

    // MARK: - Content area

    private var content: some View {
        Group {
            if nodes.isEmpty && !monitor.isPolling {
                VStack(spacing: 12) {
                    Image(systemName: "macwindow.tooltop")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text(L10n.t("workspace_panel_empty"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .font(.caption)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(nodes) { node in
                            WorkspaceNodeRow(node: node)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            let running = monitor.runningAgentCount
            let completed = monitor.completedAgentCount
            let total = monitor.agents.count
            Text(total == 0
                 ? L10n.t("workspace_footer_idle")
                 : "\(running): \(completed)/\(total)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Expandable tree node row

struct WorkspaceNodeRow: View {
    var node: WorkspaceNode
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Parent row (always visible)
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: node.kind.icon)
                        .foregroundStyle(node.kind.iconColor)
                        .frame(width: 16)

                    statusDot

                    if expanded {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 14)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 14)
                    }

                    Text(node.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 6)

                    if node.status == .running {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Children (shown when expanded)
            if expanded && !node.children.isEmpty {
                childrenSection
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06)))
    }

    private var statusDot: some View {
        Circle()
            .fill(node.status.dotColor)
            .frame(width: 7, height: 7)
            .overlay(
                Circle().stroke(.white.opacity(0.3), lineWidth: 0.5)
            )
    }

    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(node.children) { child in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: child.kind.icon)
                            .foregroundStyle(child.kind.iconColor)
                            .font(.caption2)
                            .frame(width: 14)

                        Text(child.title)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if !child.preview.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(child.preview)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary.opacity(0.85))
                                .textSelection(.enabled)
                        }
                        .padding(6)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
        }
        .padding(.leading, 28)
    }
}
