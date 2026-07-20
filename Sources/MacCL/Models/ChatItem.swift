import Foundation

/// A rendered element in the conversation transcript.
struct ChatItem: Identifiable, Codable, Equatable {
    let id: String
    var kind: Kind

    enum Kind: Codable, Equatable {
        case user(text: String, attachments: [Attachment])
        case assistantText(String)
        case thinking(String)
        case tool(ToolActivity)
        case result(ResultInfo)
        case notice(Notice)
    }
}

/// A tool invocation and (once it arrives) its result.
struct ToolActivity: Codable, Equatable {
    let toolUseId: String
    let name: String
    let input: JSONValue
    var resultText: String?
    var isError: Bool = false
    var isRunning: Bool = true

    /// A short, human-friendly description of what the tool is doing.
    var headline: String {
        switch name {
        case "Bash":
            return input["command"]?.asString ?? "commande shell"
        case "Read":
            return input["file_path"]?.asString ?? "lecture"
        case "Edit", "Write":
            return input["file_path"]?.asString ?? name
        case "Grep":
            return input["pattern"]?.asString ?? "recherche"
        case "Glob":
            return input["pattern"]?.asString ?? "glob"
        case "WebFetch":
            return input["url"]?.asString ?? "web"
        case "Task":
            return input["description"]?.asString ?? "sous-agent"
        default:
            return input.oneLineSummary(maxLength: 80)
        }
    }
}

/// Terminal result of a turn.
struct ResultInfo: Codable, Equatable {
    let isError: Bool
    let text: String?
    let costUsd: Double?
    let durationMs: Int?
    let numTurns: Int?
}

/// A non-message status line (session start, engine errors, etc.).
struct Notice: Codable, Equatable {
    enum Level: String, Codable { case info, warning, error }
    let level: Level
    let text: String
    /// Long-form content kept out of the transcript — shown on demand (tooltip
    /// + expandable). Optional so conversations saved before it existed decode.
    var detail: String?
}
