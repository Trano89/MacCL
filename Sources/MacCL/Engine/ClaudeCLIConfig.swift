import Foundation

/// Reads and updates Claude Code's own settings file (`~/.claude/settings.json`).
///
/// Writing the app's tuning there — rather than only injecting it into the child
/// process — makes it the CLI's *official* preference: it is the documented
/// mechanism, and it also applies when the user runs `claude` from a terminal.
///
/// One hard rule: never set the same key in BOTH settings.json and the child's
/// environment. Measured on the CLI — 512000 in settings.json together with
/// 256000 in the environment made it fall back to its 32000 default instead of
/// honouring either. Single source, always.
enum ClaudeCLIConfig {

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Merge entries into the file's `env` block, preserving every other key —
    /// this file is the user's, the app only owns the values it writes.
    /// Returns nil on success, else why it failed.
    @discardableResult
    static func setEnv(_ updates: [String: String]) -> String? {
        let url = settingsURL
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        // Values may legitimately be numbers or bools in someone's hand-written
        // file; normalise to strings, which is what the CLI expects.
        var env: [String: String] = [:]
        for (key, value) in (root["env"] as? [String: Any] ?? [:]) {
            env[key] = (value as? String) ?? String(describing: value)
        }
        for (key, value) in updates { env[key] = value }
        root["env"] = env

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The CLI silently clamps a larger request down to this. Measured: asking
    /// for 512000 makes it send `max_tokens: 128000`, for every model and
    /// through every configuration mechanism. Offering more would be a lie.
    static let maxOutputCeiling = 128_000
}
