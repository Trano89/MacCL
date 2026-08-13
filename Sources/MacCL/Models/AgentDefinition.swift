import Foundation

/// One sub-agent the conversation can delegate to — the app's view of a
/// `.claude/agents/<name>.md` file.
///
/// The format is Claude Code's own, not an invention of this app: YAML-ish
/// frontmatter (`name`, `description`, `tools`, `model`) followed by the agent's
/// system prompt. Writing that file is the *entire* mechanism — the CLI picks it
/// up on its own and the `model:` line is honoured verbatim (verified on the
/// wire: the sub-agent's `/v1/messages` request carries exactly that name).
///
/// The one addition MacCL makes is the `@server` suffix on the model. A process
/// running `claude` has a single `ANTHROPIC_BASE_URL`, so a sub-agent cannot
/// reach another machine by itself; the suffix names the machine and
/// `AgentRouter` peels it off and forwards the request there. Without a suffix
/// the agent stays on the conversation's own server, and no router is involved.
struct AgentDefinition: Identifiable, Hashable {
    /// Filename without `.md` — also the `subagent_type` the model calls.
    var name: String
    /// Shown to the main model to decide when to delegate. Claude Code requires
    /// it: an agent with no description is never selected.
    var description: String
    /// Tool names the agent may use. Empty = inherit the full toolset.
    var tools: [String]
    /// The bare model name as the Ollama server knows it (no `@server` suffix).
    /// Empty = `inherit`, i.e. the conversation's own model.
    var model: String
    /// Name of the `StandbyServer` this agent runs on. Empty = the
    /// conversation's server, which needs no routing at all.
    var serverName: String
    /// The agent's system prompt.
    var prompt: String

    var id: String { name }

    var filename: String { name + ".md" }

    /// What goes on the `model:` line — and, for a routed agent, exactly what
    /// arrives in the request body for `AgentRouter` to dispatch on.
    var modelField: String {
        guard !model.isEmpty else { return "inherit" }
        return serverName.isEmpty ? model : "\(model)\(Self.serverSeparator)\(serverName)"
    }

    /// `@` is in the CLI's own model-name character class, so it survives
    /// alias resolution untouched instead of being sanitized away.
    static let serverSeparator = "@"

    /// Split a wire model name back into (model, serverName). The separator is
    /// searched from the END: Ollama names may contain `@` themselves in a
    /// digest form (`model@sha256:…`), and the routing suffix is always last.
    static func splitModelField(_ raw: String) -> (model: String, serverName: String) {
        guard let idx = raw.lastIndex(of: Character(serverSeparator)) else { return (raw, "") }
        let server = String(raw[raw.index(after: idx)...])
        // A digest suffix is not a server name — those start with an algorithm
        // label and contain a colon, which a StandbyServer name never does.
        guard !server.isEmpty, !server.contains(":") else { return (raw, "") }
        return (String(raw[raw.startIndex..<idx]), server)
    }

    // MARK: - Serialization

    /// The file exactly as Claude Code expects to read it.
    func fileContents() -> String {
        var lines = ["---"]
        lines.append("name: \(name)")
        lines.append("description: \(Self.escapeScalar(description))")
        if !tools.isEmpty { lines.append("tools: \(tools.joined(separator: ", "))") }
        lines.append("model: \(modelField)")
        lines.append("---")
        lines.append("")
        lines.append(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// A description containing `:` or `#` would break the frontmatter parse.
    /// Quote defensively rather than trusting the text the user typed.
    private static func escapeScalar(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.contains(":") || flat.contains("#") || flat.hasPrefix("\"") else { return flat }
        return "\"" + flat.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Parse a `.claude/agents/*.md` file. Returns nil when it carries no
    /// frontmatter at all — that is not one of our files and must not be
    /// silently rewritten.
    static func parse(filename: String, contents: String) -> AgentDefinition? {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }

        var fields: [String: String] = [:]
        for line in lines[..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
            }
            fields[key] = value
        }

        let body = lines[lines.index(after: end)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawModel = fields["model"] ?? "inherit"
        let (model, server) = rawModel == "inherit" ? ("", "") : splitModelField(rawModel)
        let stem = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename

        return AgentDefinition(
            name: fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? stem,
            description: fields["description"] ?? "",
            tools: (fields["tools"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            model: model,
            serverName: server,
            prompt: body
        )
    }

    /// Filenames become `subagent_type` values, so they must be plain. Returns
    /// nil for anything that would escape the agents directory.
    static func sanitizeName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".md") { name = String(name.dropLast(3)) }
        name = name.replacingOccurrences(of: " ", with: "-")
        // Keep the character class Claude Code accepts for an agent type.
        name = name.filter { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !name.isEmpty, name != "-", name != "_" else { return nil }
        return String(name.prefix(64))
    }
}
