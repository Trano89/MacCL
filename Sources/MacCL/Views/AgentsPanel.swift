import SwiftUI

/// Right-hand panel: what the conversation's sub-agents are doing, right now.
///
/// A sub-agent used to be a black box — an Agent card that spun until it didn't.
/// This shows the same material the main transcript is built from, scoped to one
/// agent: what it's thinking, which tools it's running, what it answered. And,
/// because the conversation can send its sub-agents to another model on another
/// machine, which brain actually answered — read off the agent's own events, so
/// it describes the run in front of you rather than the setting as it stands now.
struct AgentsPanel: View {
    @ObservedObject var vm: ChatViewModel
    /// Opens the sub-agent model choice — the setting that decides what these
    /// agents think with, one click from the agents themselves.
    var onManage: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Theme.card.opacity(0.5))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(L10n.t("agents_title"), systemImage: "person.2.gobackward")
                .font(.headline)
            if vm.runningAgentCount > 0 {
                ProgressView().controlSize(.mini)
                Text("\(vm.runningAgentCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
            Button(action: onManage) {
                Image(systemName: "cpu").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.t("model_for_subagents"))
            Button {
                vm.showAgentsPanel = false
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("close"))
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        let agents = vm.agents
        if agents.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Text(L10n.t("agents_empty"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: onManage) {
                    Label(L10n.t("model_for_subagents"), systemImage: "cpu")
                }
                .buttonStyle(.link)
                Spacer()
            }
            .padding(20)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(agents) { agent in
                        AgentCard(agent: agent,
                                  run: vm.agentRuns[agent.id],
                                  isSelected: vm.selectedAgentId == agent.id) {
                            vm.selectedAgentId = vm.selectedAgentId == agent.id ? nil : agent.id
                        }
                    }
                }
                .padding(10)
            }
        }
    }
}

/// One agent: header always visible, its whole working record when expanded.
private struct AgentCard: View {
    let agent: ChatViewModel.AgentInfo
    let run: ChatViewModel.AgentRun?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerButton
            if isSelected {
                Divider()
                detail
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner)
            .stroke(isSelected ? Theme.accent.opacity(0.4) : Theme.hairline))
    }

    private var headerButton: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                statusDot.padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.description)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    typeAndStatus
                    backendChip
                }
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(10)
    }

    private var typeAndStatus: some View {
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
            if let count = toolCount {
                Text(count)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Which brain, and where. Absent until the agent's first event lands —
    /// showing the definition instead would be a guess dressed as a fact.
    @ViewBuilder private var backendChip: some View {
        if let model = run?.modelName {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(model)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let machine = run?.machineName {
                    Image(systemName: "network")
                    Text(machine).lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.accent)
        }
    }

    private var toolCount: String? {
        guard let n = run?.tools.count, n > 0 else { return nil }
        return "· \(n) ⚒"
    }

    // MARK: Expanded body

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reasoning = run?.reasoning, !reasoning.isEmpty {
                ReasoningPanel(text: reasoning, isLive: agent.isRunning)
            }
            toolList
            if let text = run?.text, !text.isEmpty {
                labeled(L10n.t("agent_answer")) {
                    Text(verbatim: text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let result = agent.resultText, !result.isEmpty {
                labeled(L10n.t("agent_result")) {
                    ScrollView {
                        Text(verbatim: result)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            }
            if !agent.prompt.isEmpty { instructionsBlock }
        }
        .padding(10)
    }

    @ViewBuilder private var toolList: some View {
        if let tools = run?.tools, !tools.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("agent_activity"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                // The transcript's own card, flush instead of indented: a tool
                // call should read the same wherever it is shown.
                ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                    ToolCallView(activity: tool, indent: 0)
                }
            }
        }
    }

    private var instructionsBlock: some View {
        labeled(L10n.t("agent_instructions")) {
            ScrollView {
                Text(verbatim: agent.prompt)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)
        }
    }

    private func labeled<Content: View>(_ title: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .padding(8)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8))
        }
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
