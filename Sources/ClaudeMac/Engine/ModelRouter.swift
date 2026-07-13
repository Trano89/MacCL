import Foundation

/// Computes the environment that points `claude` at the right backend for a
/// given model, and (for local providers) ensures the translation router runs.
///
/// - Anthropic models: no override — `claude` uses its own auth.
/// - Ollama models: `claude` is pointed at a local Anthropic→Ollama router that
///   translates the Messages API into Ollama's `/api/chat`.
@MainActor
final class ModelRouter {
    static let shared = ModelRouter()

    private let proxy = RouterProcess()
    /// Ollama models we've loaded this session — unloaded when the app quits.
    private var usedModels: Set<String> = []

    /// Environment overrides for the child `claude` process.
    func environment(for model: LLMModel, settings: AppSettings) -> [String: String] {
        switch model.provider {
        case .anthropic:
            return [:]
        case .ollama:
            usedModels.insert(model.modelArg)
            return [
                "ANTHROPIC_BASE_URL": settings.routerBaseURL,
                "ANTHROPIC_API_KEY": "ollama-local",
                "ANTHROPIC_MODEL": model.modelArg,
                // Small/fast model calls also go through the local router.
                "ANTHROPIC_SMALL_FAST_MODEL": model.modelArg,
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            ]
        }
    }

    /// Ensure the router is running for local providers. Returns an error string
    /// if it could not be started.
    func prepare(for model: LLMModel, settings: AppSettings) async -> String? {
        guard model.provider == .ollama else { return nil }
        return await proxy.ensureRunning(port: settings.routerPort,
                                         ollamaBaseURL: settings.ollamaBaseURL,
                                         numCtx: settings.ollamaNumCtx,
                                         think: settings.showReasoning,
                                         maxPredict: settings.ollamaMaxPredict)
    }

    func shutdown() {
        proxy.stop()
    }

    /// Called on app quit: unload the models we loaded, then stop the router.
    /// Models stay resident (keep_alive:-1) while the app runs; this is the only
    /// place they're released.
    func cleanupOnQuit(baseURL: String) {
        for model in usedModels {
            unloadSync(model: model, baseURL: baseURL)
        }
        proxy.stop()
    }

    private func unloadSync(model: String, baseURL: String) {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: base + "/api/generate") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1.5
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 2)
    }
}
