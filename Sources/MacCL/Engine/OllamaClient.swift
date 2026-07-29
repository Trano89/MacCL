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
        /// Architecture family ("qwen35moe", "llama"…). Two models of the same
        /// family speak the same tool-call syntax, so one can lend its parser.
        let family: String?
        /// Built-in renderer/parser declared by the model, if any.
        let renderer: String?
        let parser: String?
        /// Sampling settings baked into the model (temperature, top_k…).
        let parameters: [String: String]

        /// A tool-capable model that declares no parser forces Ollama to GENERATE
        /// one from the model's Jinja template. Community repacks often ship
        /// templates that make that generation fail outright ("Automatic parser
        /// generation failed"), so the model 400s the moment tools are involved.
        var lacksToolParser: Bool { capabilities.contains("tools") && parser == nil }
    }

    static func details(model: String, baseURL: String) async -> ModelDetails? {
        guard let url = URL(string: baseURL.trimmingTrailingSlash + "/api/show") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 4
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let caps = obj["capabilities"] as? [String] ?? []
        let info = obj["model_info"] as? [String: Any] ?? [:]
        let ctx = info.first { $0.key.hasSuffix(".context_length") }?.value as? Int
        let family = (obj["details"] as? [String: Any])?["family"] as? String

        // The Modelfile is the only place RENDERER/PARSER/PARAMETER show up.
        var renderer: String?
        var parser: String?
        var parameters: [String: String] = [:]
        for rawLine in (obj["modelfile"] as? String ?? "").split(separator: "\n") {
            let parts = rawLine.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0].uppercased() {
            case "RENDERER": renderer = value
            case "PARSER": parser = value
            case "PARAMETER":
                let kv = value.split(separator: " ", maxSplits: 1).map(String.init)
                if kv.count == 2 { parameters[kv[0]] = kv[1].trimmingCharacters(in: .whitespaces) }
            default: break
            }
        }
        return ModelDetails(capabilities: caps, contextMax: ctx, family: family,
                            renderer: renderer, parser: parser, parameters: parameters)
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

    // MARK: - Model management (remote server, plain HTTP API)

    struct InstalledModel: Identifiable {
        var id: String { name }
        let name: String
        let sizeBytes: Int64
    }

    /// Installed models with their disk size — the management view's listing.
    static func installedModels(baseURL: String) async -> [InstalledModel] {
        guard let url = URL(string: baseURL.trimmingTrailingSlash + "/api/tags") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { m in
            guard let name = m["name"] as? String else { return nil }
            return InstalledModel(name: name, sizeBytes: (m["size"] as? Int64) ?? Int64(m["size"] as? Int ?? 0))
        }
    }

    private static func post(_ path: String, body: [String: Any], baseURL: String,
                             timeout: TimeInterval = 30, method: String = "POST") async -> String? {
        guard let url = URL(string: baseURL.trimmingTrailingSlash + path) else { return "URL invalide" }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                return msg ?? "HTTP \(code)"
            }
            return nil
        } catch { return error.localizedDescription }
    }

    /// Delete a model from the server. nil on success, else the server's error.
    static func deleteModel(_ model: String, baseURL: String) async -> String? {
        await post("/api/delete", body: ["model": model], baseURL: baseURL, method: "DELETE")
    }

    /// Duplicate a model under a new name (instant, server-side).
    static func copyModel(_ source: String, to destination: String, baseURL: String) async -> String? {
        await post("/api/copy", body: ["source": source, "destination": destination], baseURL: baseURL)
    }

    /// Create a derived model (`from` + parameters, e.g. num_ctx) — how you bake
    /// a context size into a model of your own on the server.
    /// `renderer`/`parser` name Ollama's built-in implementations; passing them
    /// is what spares the server from generating a parser out of the Jinja
    /// template. Creation reuses the base model's layers: no re-download.
    static func createModel(name: String, from base: String, parameters: [String: Any],
                            renderer: String? = nil, parser: String? = nil,
                            baseURL: String) async -> String? {
        var body: [String: Any] = ["model": name, "from": base, "stream": false]
        if !parameters.isEmpty { body["parameters"] = parameters }
        if let renderer { body["renderer"] = renderer }
        if let parser { body["parser"] = parser }
        return await post("/api/create", body: body, baseURL: baseURL, timeout: 600)
    }

    // MARK: - Tool-parser repair

    /// A model on `baseURL` that can lend its built-in tool parser to `model`:
    /// same architecture family, and it actually declares one.
    static func parserDonor(for model: String, details: [String: ModelDetails])
        -> (name: String, renderer: String?, parser: String)? {
        guard let family = details[model]?.family else { return nil }
        return details
            .filter { $0.key != model && $0.value.family == family && $0.value.parser != nil }
            .sorted { $0.key < $1.key }             // stable pick across refreshes
            .first
            .map { (name: $0.key, renderer: $0.value.renderer, parser: $0.value.parser!) }
    }

    /// Name proposed for the repaired copy: `…/Qwen3.6-Foo-GGUF:Q8_0` → `qwen3.6-foo:q8_0-fixed`.
    static func repairedName(for model: String) -> String {
        let lastPath = model.split(separator: "/").last.map(String.init) ?? model
        let parts = lastPath.split(separator: ":", maxSplits: 1).map(String.init)
        var slug = parts[0].lowercased()
        if slug.hasSuffix("-gguf") { slug = String(slug.dropLast(5)) }
        slug = slug.replacingOccurrences(of: "[^a-z0-9._-]", with: "-", options: .regularExpression)
        let tag = parts.count > 1 ? parts[1].lowercased() : "latest"
        return "\(slug):\(tag)-fixed"
    }

    /// Numbers must reach Ollama as numbers — a quoted "1.5" is rejected.
    private static func typed(_ parameters: [String: String]) -> [String: Any] {
        parameters.mapValues { value -> Any in
            if let i = Int(value) { return i }
            if let d = Double(value) { return d }
            return value
        }
    }

    /// Rebuild `model` as `newName` with a donor's built-in renderer/parser, so
    /// tool calling stops depending on parser generation. The original is left
    /// untouched. nil on success, else why not.
    @MainActor
    static func repairToolParser(model: String, as newName: String,
                                 details: [String: ModelDetails], baseURL: String) async -> String? {
        guard let donor = parserDonor(for: model, details: details) else {
            return L10n.t("repair_no_donor")
        }
        // Keep the model's own sampling settings; fall back to the donor's when
        // the repack shipped none (community GGUFs frequently ship none).
        let ownParams = details[model]?.parameters ?? [:]
        let params = ownParams.isEmpty ? (details[donor.name]?.parameters ?? [:]) : ownParams
        return await createModel(name: newName, from: model, parameters: typed(params),
                                 renderer: donor.renderer, parser: donor.parser, baseURL: baseURL)
    }

    /// Download a model onto the server, streaming progress lines as they come.
    /// Returns nil on success, else an error message.
    static func pullModel(_ model: String, baseURL: String,
                          progress: @MainActor @escaping (String) -> Void) async -> String? {
        guard let url = URL(string: baseURL.trimmingTrailingSlash + "/api/pull") else { return "URL invalide" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3600   // a 20 GB model takes what it takes
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            var lastPercent = -1
            for try await line in bytes.lines {
                guard let obj = try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)) as? [String: Any] else { continue }
                if let err = obj["error"] as? String { return err }
                let status = obj["status"] as? String ?? ""
                if let total = obj["total"] as? Double, total > 0,
                   let done = obj["completed"] as? Double {
                    let pct = Int(done / total * 100)
                    if pct != lastPercent {   // one line per percent, not per chunk
                        lastPercent = pct
                        await progress("\(status) — \(pct)% (\(Int64(done).formattedBytes) / \(Int64(total).formattedBytes))")
                    }
                } else if !status.isEmpty {
                    await progress(status)
                }
            }
            return nil
        } catch { return error.localizedDescription }
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

extension Int64 {
    /// 21909210142 → "20,4 Go" (localized byte count for model sizes).
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
