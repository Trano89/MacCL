import Foundation

/// Tracks sub-agents (Claude Code `Task` tool calls) launched during the current turn.
/// Status flows: queued → running → completed | failed
struct AgentState: Identifiable, Equatable {
    let id: String          // toolUseId
    var description: String
    var name: String        // agent label shown to user (from input.description or auto-named)
    var status: Status      // queued / running / completed / failed

    var isActive: Bool { status == .running || status == .queued }
    var isFinished: Bool { status == .completed || status == .failed }

    enum Status: String, Codable {
        case queued
        case running
        case completed
        case failed

        /// Color for the status dot (hex string).
        var dotColor: String {
            switch self {
            case .queued:    return "808090"  // muted grey
            case .running:   return "F59E0B"  // amber
            case .completed: return "10B981"  // green
            case .failed:    return "EF4444"  // red
            }
        }

        var icon: String {
            switch self {
            case .queued:    return "circle.dashed"
            case .running:   return "arrow.triangle.clockwise"
            case .completed: return "checkmark.circle.fill"
            case .failed:    return "xmark.circle.fill"
            }
        }
    }

    static func == (lhs: AgentState, rhs: AgentState) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status
    }
}

// NOTE: AgentMonitorParser was removed in the dead-code cleanup.
// The struct/AgentState data types remain for backward-compat with saved conversations;
// live parsing is now done directly in ChatViewModel.
