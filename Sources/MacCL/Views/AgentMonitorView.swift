import SwiftUI

/// Slide-in panel (right side) showing sub-agent activity.
struct AgentMonitorPanel: View {
    @ObservedObject var monitor: AgentMonitorModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 280, maxWidth: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.3.fill")
                .foregroundStyle(Theme.accent)
            Text(L10n.t("agent_monitor_title"))
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

    private var content: some View {
        Group {
            if monitor.agents.isEmpty && !monitor.isPolling {
                VStack(spacing: 12) {
                    Image(systemName: "person.3")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text(L10n.t("agent_monitor_empty"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(monitor.agents) { agent in
                            agentRow(agent)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func agentRow(_ agent: AgentState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hexRGB: agent.status.dotColor))
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle().stroke(.white.opacity(0.3), lineWidth: 1)
                    )

                // Animated pulse ring for running agents
                if agent.status == .running {
                    statusPulse
                }

                Text(agent.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Image(systemName: agent.status.icon)
                    .font(.caption)
                    .foregroundStyle(Color(hexRGB: agent.status.dotColor).opacity(agent.status == .running ? 0.9 : 0.85))
            }

            if !agent.description.isEmpty {
                Text(agent.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06)))
    }

    private var statusPulse: some View {
        Circle()
            .fill(Color(hexRGB: "F59E0B").opacity(0.25))
            .frame(width: 8, height: 8)
            .scaleEffect(monitor.pulseScale > 1 ? 2.5 : 1)
            .opacity(monitor.pulseScale < 1 ? 0 : 0.25)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            let running = monitor.runningAgentCount
            let completed = monitor.completedAgentCount
            let total = monitor.agents.count
            Text(total == 0
                 ? L10n.t("agent_monitor_footer_idle")
                 : "\(running): \(completed)/\(total)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - AgentMonitorModel

@MainActor
final class AgentMonitorModel: ObservableObject {
    @Published var agents: [AgentState] = []
    private var _seenDescriptions: Set<String> = []
    let isPolling: Bool

    var hasActiveAgents: Bool { agents.contains(where: \.isActive) }
    var runningAgentCount: Int { agents.filter(\.isActive).count }
    var completedAgentCount: Int { agents.filter(\.isFinished).count }

    /// Pulse animation value for running indicator, driven by a timer.
    @Published var pulseScale = 1.0
    private var pulseTimer: Timer?

    init() {
        isPolling = false
        _setupPulseTimer()
    }

    /// Re-init the pulse timer (used after clearAll to restart it).
    private func _setupPulseTimer() {
        // Invalidate any existing timer first.
        pulseTimer?.invalidate()
        pulseScale = 1.0
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                let current = (self?.pulseScale ?? 1.0)
                self?.pulseScale = current > 1 ? 1.0 : 1.5
            }
        }
    }

    deinit {
        pulseTimer?.invalidate()
    }

    /// Called when a Task tool_use arrives in an assistant message.
    func addAgent(description: String, name: String?, status: AgentState.Status = .running) {
        // Skip duplicate descriptions from the same turn.
        guard !_seenDescriptions.contains(description) else { return }
        _seenDescriptions.insert(description)

        let agentName: String
        if let name, !name.isEmpty, name != description {
            agentName = String(name.prefix(50))
        } else {
            agentName = String(description.prefix(50))
        }

        let state = AgentState(
            id: UUID().uuidString,
            description: description,
            name: agentName,
            status: status
        )
        agents.append(state)
    }

    /// Called when a tool_result for a Task arrives.
    func onTaskResult(toolUseId: String?, output: String?) {
        guard let id = toolUseId else { return }
        guard let idx = agents.firstIndex(where: { $0.id == id || $0.description == id }) else { return }

        if let output, !output.isEmpty {
            agents[idx].status = .completed
            let preview = String(output.prefix(80)) + (output.count > 80 ? "…" : "")
            agents[idx].name = preview
        } else {
            agents[idx].status = .failed
        }
    }

    /// Settle all agents to completed when a turn finishes.
    func settleTurn() {
        for i in agents.indices where agents[i].isActive {
            agents[i].status = .completed
        }
    }

    /// Clear all agents (new turn or new conversation).
    func clearAll() {
        agents.removeAll()
        _seenDescriptions.removeAll()
        pulseScale = 1.0
    }
}

// MARK: - Helpers

extension Color {
    /// Create color from hex RGB string (6 digits, no alpha).
    init(hexRGB hex: String) {
        var hexClean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        while hexClean.count < 6 { hexClean = "0" + hexClean }
        guard let value = UInt64(hexClean, radix: 16) else {
            self = .white
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
