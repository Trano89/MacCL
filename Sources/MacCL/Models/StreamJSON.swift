import Foundation

/// One decoded line of `claude --output-format stream-json` output.
///
/// The protocol emits newline-delimited JSON objects discriminated by `type`.
/// We decode leniently: unknown fields are ignored and unknown `type`s are
/// preserved via the raw `type` string so the UI can surface them.
/// P1 fix: Stream protocol v2 — added `protocolVersion` for backwards compatibility.
/// Event types: system/init, assistant (with ContentBlock[]), user (with ContentBlock[]),
/// result (with isError/cost/turns/duration), stream_event (delta), control_request.
struct StreamEnvelope: Decodable {
    let type: String
    let subtype: String?

    // system / init
    let sessionId: String?
    let cwd: String?
    let model: String?
    let tools: [String]?
    let permissionMode: String?
    let slashCommands: [String]?
    let apiKeySource: String?
    let claudeCodeVersion: String?

    // assistant / user
    let message: AnthropicMessage?
    let parentToolUseId: String?

    // result
    let isError: Bool?
    /// May arrive as a plain string or as a structured object (e.g. {"text": "..."}).
    /// JSONValue preserves both shapes; .unknown catches non-standard payloads.
    let result: JSONValue?
    let totalCostUsd: Double?
    let numTurns: Int?
    let durationMs: Int?
    let usage: JSONValue?
    let stopReason: String?

    // control protocol
    let requestId: String?
    let request: JSONValue?
    let response: JSONValue?

    // partial streaming (`--include-partial-messages`)
    let event: JSONValue?

    let uuid: String?

    enum CodingKeys: String, CodingKey {
        case type, subtype, message, cwd, tools, model, result, usage, event, request, response, uuid
        case sessionId = "session_id"
        case permissionMode
        case slashCommands = "slash_commands"
        case apiKeySource
        case claudeCodeVersion = "claude_code_version"
        case parentToolUseId = "parent_tool_use_id"
        case isError = "is_error"
        case totalCostUsd = "total_cost_usd"
        case numTurns = "num_turns"
        case durationMs = "duration_ms"
        case stopReason = "stop_reason"
        case requestId = "request_id"
    }
}

/// An Anthropic Messages-API message as embedded in `assistant` / `user` events.
struct AnthropicMessage: Decodable {
    let role: String?
    let model: String?
    let content: [ContentBlock]?
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case role, model, content
        case stopReason = "stop_reason"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try? c.decode(String.self, forKey: .role)
        model = try? c.decode(String.self, forKey: .model)
        stopReason = try? c.decode(String.self, forKey: .stopReason)
        // `content` may be a plain string (user shorthand) or an array of blocks.
        if let blocks = try? c.decode([ContentBlock].self, forKey: .content) {
            content = blocks
        } else if let text = try? c.decode(String.self, forKey: .content) {
            content = [.text(text)]
        } else {
            content = nil
        }
    }
}

/// A single content block inside an Anthropic message.
enum ContentBlock: Decodable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, text: String, isError: Bool)
    case unknown(type: String)

    private enum K: String, CodingKey {
        case type, text, thinking, id, name, input, content
        case toolUseId = "tool_use_id"
        case isError = "is_error"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? "unknown"
        switch type {
        case "text":
            self = .text((try? c.decode(String.self, forKey: .text)) ?? "")
        case "thinking":
            self = .thinking((try? c.decode(String.self, forKey: .thinking)) ?? "")
        case "tool_use":
            let id = (try? c.decode(String.self, forKey: .id)) ?? ""
            let name = (try? c.decode(String.self, forKey: .name)) ?? ""
            let input = (try? c.decode(JSONValue.self, forKey: .input)) ?? .object([:])
            self = .toolUse(id: id, name: name, input: input)
        case "tool_result":
            let tid = (try? c.decode(String.self, forKey: .toolUseId)) ?? ""
            let isErr = (try? c.decode(Bool.self, forKey: .isError)) ?? false
            self = .toolResult(toolUseId: tid, text: Self.decodeContent(c), isError: isErr)
        default:
            self = .unknown(type: type)
        }
    }

    /// tool_result `content` can be a string, an array of `{type:text,text}`,
    /// or (rarely) a bare "text" field at the top level.  Returns "".only when
    /// the server truly sent nothing — not when it silently dropped data.
    private static func decodeContent(_ c: KeyedDecodingContainer<K>) -> String {
        // Try known keys in order of prevalence.
        if let s = try? c.decode(String.self, forKey: .content) { return s }
        if let arr = try? c.decode([JSONValue].self, forKey: .content) {
            let parts = arr.compactMap { block -> String? in
                if case .object(let o) = block {
                    if let t = o["text"]?.asString { return t }
                    if let t = o["content"]?.asString { return t }
                }
                return block.asString
            }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        // Some implementations use a bare "text" key instead of "content".
        if let v = try? c.decode(JSONValue.self, forKey: .text) { return v.pretty() }
        // Last resort: any leftover JSONValue on the raw "content" key.
        if let v = try? c.decode(JSONValue.self, forKey: .content) { return v.pretty() }
        return ""
    }
}
