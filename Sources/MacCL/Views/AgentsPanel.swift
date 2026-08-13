import SwiftUI

/// Right-hand panel: the conversation's sub-agents — their instructions, live
/// activity, and outcome. Opened from the link on a Task card, or stays open
/// while agents run.
struct AgentsPanel: View {
    @ObservedObject var vm: ChatViewModel
    @ObservedObject private var store = AgentStore.shared

    /// Which model, and which machine, this sub-agent's definition sends it to.
    /// Nil for a built-in agent type, which simply inherits the conversation's.
    private func backend(for agent: ChatViewModel.AgentInfo) -> String? {
        guard let type = agent.type,
              let def = store.agents.first(where: { $0.name == type }),
              !def.model.isEmpty else { return nil }
        return def.serverName.isEmpty ? def.model : "\(def.model) · \(def.serverName)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.t("agents_title"), systemImage: "person.2.gobackward")
                    .font(.headline)
                Spacer()
                Button {
                    vm.showAgentsPanel = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("close"))
            }
            .padding(12)
            Divider()

            let agents = vm.agents
            if agents.isEmpty {
                Spacer()
                Text(L10n.t("agents_empty"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(20)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(agents) { agent in
                            AgentCard(agent: agent,
                                      backend: backend(for: agent),
                                      activity: vm.agentActivity[agent.id] ?? [],
                                      isSelected: vm.selectedAgentId == agent.id) {
                                vm.selectedAgentId = vm.selectedAgentId == agent.id ? nil : agent.id
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Theme.card.opacity(0.5))
    }
}

/// One agent: header always visible, detail (instructions, activity, result)
/// when selected.
private struct AgentCard: View {
    let agent: ChatViewModel.AgentInfo
    /// "model · machine" when the agent's definition overrides them.
    let backend: String?
    let activity: [String]
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    statusDot
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.description)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if let type = agent.type {
                                Text(type)
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Theme.accentSoft, in: Capsule())
                            }
                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        // Which brain actually answered. Without it, a sub-agent
                        // routed to another machine looks exactly like one that
                        // silently fell back to the conversation's model.
                        if let backend {
                            Label(backend, systemImage: "cpu")
                                .font(.caption2)
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)

            if isSelected {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if !agent.prompt.isEmpty {
                        Text(L10n.t("agent_instructions"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            Text(verbatim: agent.prompt)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                        .padding(8)
                        .background(Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !activity.isEmpty {
                        Text(L10n.t("agent_activity"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(activity.suffix(8).enumerated()), id: \.offset) { _, line in
                                Text(verbatim: line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    if let result = agent.resultText, !result.isEmpty {
                        Text(L10n.t("agent_result"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            Text(verbatim: result)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                        .padding(8)
                        .background(Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(10)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner)
            .stroke(isSelected ? Theme.accent.opacity(0.4) : Theme.hairline))
    }

    private var statusDot: some View {
        Circle()
            .fill(agent.isRunning ? Color.orange : (agent.isError ? .red : .green))
            .frame(width: 8, height: 8)
    }

    private var statusText: String {
        agent.isRunning ? L10n.t("agent_running")
            : agent.isError ? L10n.t("agent_failed") : L10n.t("agent_done")
    }
}
