import Foundation

extension OllamaClient {

    /// Which `output_config.effort` values a model's chat template will accept,
    /// or nil when it doesn't constrain them.
    ///
    /// Claude Code forwards the effort verbatim — `/effort max` becomes
    /// `"output_config": {"effort": "max"}` (captured) — and Ollama hands it to
    /// the Jinja template as `reasoning_effort`. Several Qwen templates validate
    /// it and `raise_exception` on anything else, which comes back as a hard
    /// HTTP 500 and kills the turn. Qwen3.8 accepts only xhigh, medium and low,
    /// so even the CLI's own default of `high` fails against it.
    static func supportedReasoningEfforts(model: String, baseURL: String) async -> Set<String>? {
        let key = model + "@" + baseURL
        if let cached = effortCache.value(for: key) { return cached.value }

        guard let url = URL(string: baseURL.trimmingTrailingSlash + "/api/show") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let template = obj["template"] as? String else { return nil }

        let found = parseSupportedEfforts(template)
        effortCache.store(Box(found), for: key)
        return found
    }

    /// The guard looks like `{%- if resolved_reasoning_effort not in ('xhigh',
    /// 'medium', 'low') %}`; take the quoted values from that tuple.
    static func parseSupportedEfforts(_ template: String) -> Set<String>? {
        for line in template.split(separator: "\n") {
            let text = String(line)
            guard text.contains("reasoning_effort"), text.contains("not in") else { continue }
            guard let start = text.range(of: "not in") else { continue }
            let tail = text[start.upperBound...]
            let values = tail.split(whereSeparator: { $0 == "'" || $0 == "\"" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.allSatisfy { c in c.isLetter } }
            if !values.isEmpty { return Set(values) }
        }
        return nil
    }

    // A template never changes under a given name, so ask once per model.
    private final class Box: @unchecked Sendable { let value: Set<String>?; init(_ v: Set<String>?) { value = v } }
    private final class Cache: @unchecked Sendable {
        private var storage: [String: Box] = [:]
        private let lock = NSLock()
        func value(for key: String) -> Box? { lock.lock(); defer { lock.unlock() }; return storage[key] }
        func store(_ box: Box, for key: String) { lock.lock(); storage[key] = box; lock.unlock() }
    }
    private static let effortCache = Cache()
}
