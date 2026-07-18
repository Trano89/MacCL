import Foundation

/// Minimal client for an Ollama server.
enum OllamaClient {
    struct Model: Decodable {
        let name: String
        let details: Details?
        struct Details: Decodable {
            let parameterSize: String?
            enum CodingKeys: String, CodingKey { case parameterSize = "parameter_size" }
        }
    }

    private struct TagsResponse: Decodable { let models: [Model] }
    private struct VersionResponse: Decodable { let version: String }

    /// Per-model facts from /api/show that matter when picking one: what it can
    /// do, and its trained context ceiling (Ollama silently caps num_ctx there —
    /// asking a 40k model for 1M quietly gives 40k, so surface the number).
    struct ModelDetails {
        let capabilities: [String]
        let contextMax: Int?
    }

    static func details(model: String, baseURL: String) async -> ModelDetails? {
        guard let url = URL(string: baseURL.trimmingTrailingSlash + "/api/show") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 2.5
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let caps = obj["capabilities"] as? [String] ?? []
        let info = obj["model_info"] as? [String: Any] ?? [:]
        let ctx = info.first { $0.key.hasSuffix(".context_length") }?.value as? Int
        return ModelDetails(capabilities: caps, contextMax: ctx)
    }

    /// Returns discovered models, or an empty list if the server is unreachable.
    static func listModels(baseURL: String) async -> [LLMModel] {
        guard let url = URL(string: baseURL.trimmingTrailingSlash + "/api/tags") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            let host = URL(string: baseURL)?.host ?? "localhost"
            let names = decoded.models.map(\.name)
            // Enrich each entry with its capabilities and context ceiling, in
            // parallel — a dozen POSTs against a local server, one RTT total.
            var detailMap: [String: ModelDetails] = [:]
            await withTaskGroup(of: (String, ModelDetails?).self) { group in
                for name in names {
                    group.addTask { (name, await details(model: name, baseURL: baseURL)) }
                }
                for await (name, d) in group { detailMap[name] = d }
            }
            return names.map { name in
                LLMModel.ollama(name, host: host,
                                capabilities: detailMap[name]?.capabilities ?? [],
                                contextMax: detailMap[name]?.contextMax)
            }
        } catch {
            return []
        }
    }

    /// True if an Ollama server responds at the given base URL.
    static func isReachable(baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL.trimmingTrailingSlash + "/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Load `model` into the server's memory — or refresh its residency window —
    /// without evaluating a single prompt token. POST /api/generate with no
    /// prompt is Ollama's documented preload; `keep_alive` says how long it
    /// stays. This is what the old bridge's `keep_alive:-1` bought us, minus the
    /// bridge: fired when a conversation binds a model and after each turn, so
    /// the next turn never pays the cold load.
    static func warmUp(model: String, baseURL: String, keepAlive: String = "60m") async {
        guard let url = URL(string: baseURL.trimmingTrailingSlash + "/api/generate") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300   // a cold 30B takes minutes to come up
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["model": model, "keep_alive": keepAlive, "stream": false])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// The server's reported version (e.g. "0.32.0"), or nil if it wouldn't say.
    static func version(baseURL: String) async -> String? {
        guard let url = URL(string: baseURL.trimmingTrailingSlash + "/api/version") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(VersionResponse.self, from: data).version
        } catch {
            return nil
        }
    }

    /// Ollama serves the Anthropic Messages API (`/v1/messages`) from v0.14.0 on.
    /// That endpoint is the whole integration: without it `claude` gets nothing
    /// but transport errors.
    static func supportsAnthropicAPI(version: String) -> Bool {
        let parts = version.split(separator: ".").prefix(2).compactMap { Int($0.prefix(while: \.isNumber)) }
        guard parts.count >= 2 else { return true }  // unparseable → don't block the user
        return (parts[0], parts[1]) >= (0, 14)
    }
}
