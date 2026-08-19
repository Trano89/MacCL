import Foundation

/// How a sub-agent's model names the machine it should run on, and the little
/// that MacCL still reads out of a `.claude/agents/<name>.md` file.
///
/// A process running `claude` has a single `ANTHROPIC_BASE_URL`, so a sub-agent
/// cannot reach another machine by itself. The suffix names the machine and
/// `AgentRouter` peels it off before forwarding. Without a suffix nothing is
/// routed at all and no router is started.
///
/// The app itself no longer writes these files — the conversation's own
/// sub-agent model setting is what it offers, because that covers every agent
/// Claude Code spawns rather than only the ones someone wrote a file for. The
/// parser stays because the CLI's mechanism stays: a hand-written agent naming
/// a machine must still get a route opened for it, and only its machine is
/// needed to do that.
enum AgentDefinition {
    /// `@` is in the CLI's own model-name character class, so it survives alias
    /// resolution untouched instead of being sanitized away.
    static let serverSeparator = "@"

    /// Split a wire model name into (model, serverName). The separator is
    /// searched from the END: Ollama names may contain `@` themselves in a
    /// digest form (`model@sha256:…`), and the routing suffix is always last.
    static func splitModelField(_ raw: String) -> (model: String, serverName: String) {
        guard let idx = raw.lastIndex(of: Character(serverSeparator)) else { return (raw, "") }
        let server = String(raw[raw.index(after: idx)...])
        // A digest suffix is not a server name — those carry a colon, which a
        // StandbyServer name never does.
        guard !server.isEmpty, !server.contains(":") else { return (raw, "") }
        return (String(raw[raw.startIndex..<idx]), server)
    }

    /// The machine a `.claude/agents/*.md` file sends its agent to, or nil when
    /// it names none (the overwhelmingly common case) or carries no frontmatter.
    ///
    /// Deliberately narrow: the CLI reads these files itself for everything that
    /// matters — name, description, tools, prompt. The only thing MacCL cannot
    /// leave to it is opening a network route, so that is the only thing read.
    static func routedMachine(inFileContents contents: String) -> String? {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }

        for line in lines[..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "model" else { continue }
            var value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            guard value != "inherit" else { return nil }
            let server = splitModelField(value).serverName
            return server.isEmpty ? nil : server
        }
        return nil
    }
}
