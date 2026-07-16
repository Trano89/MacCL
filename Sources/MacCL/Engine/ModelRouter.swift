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
    /// Ollama models we've loaded this session, per server ("url|model") —
    /// unloaded from their own server when the app quits.
    private var usedModels: Set<UsedModel> = []
    private struct UsedModel: Hashable { let serverURL: String; let model: String }
    /// Periodic pinger to keep the local proxy alive even in background / between turns.
    /// Pings every 15 s; this is what prevents the "app stopped working after switching apps" bug.
    private let pinger = KeepAlivePinger()

    /// Environment overrides for the child `claude` process.
    /// Identical for every Ollama server — localhost or network, an address is
    /// just an address: `claude` always talks to the local bridge, and only the
    /// bridge's target changes.
    func environment(for model: LLMModel, settings: AppSettings, serverURL: String) -> [String: String] {
        switch model.provider {
        case .anthropic:
            return [:]
        case .ollama, .ollamaNetwork:
            usedModels.insert(UsedModel(serverURL: serverURL, model: model.modelArg))
            // Always go through a local bridge: raw Ollama speaks /api/chat, not
            // the Anthropic Messages API that Claude Code sends.
            let baseUrl = settings.bridgeEngine == .litellm
                ? settings.litellmBaseURL
                : settings.routerBaseURL
            let a = "ANTHROPIC_"
            return [
                "\(a)BASE_URL": baseUrl,
                "\(a)API_KEY": "ollama-local",
                "\(a)MODEL": model.modelArg,
                // Small/fast model calls also go through the local router.
                "\(a)SMALL_FAST_MODEL": model.modelArg,
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            ]
        }
    }

    /// Ensure the bridge is running and pointed at `serverURL` — the
    /// conversation's own server. One code path for every address.
    /// Returns an error string if it could not be started.
    func prepare(for model: LLMModel, settings: AppSettings, serverURL: String) async -> String? {
        guard model.provider == .ollama || model.provider == .ollamaNetwork else { return nil }

        // Validate port range and check no essential service is already bound before committing to ANTHROPIC_BASE_URL.
        guard settings.routerPort >= 1024 && settings.routerPort <= 65535 else {
            return L10n.t("invalid_port")
        }
        // Same validation for every server, localhost included.
        guard URLValidator.validate(serverURL) != nil else {
            return L10n.t("invalid_ollama_url")
        }

        // LiteLLM bridge: hand off to the Python proxy instead of the Node one.
        if settings.bridgeEngine == .litellm {
            guard settings.litellmPort >= 1024 && settings.litellmPort <= 65535 else {
                return L10n.t("invalid_port")
            }
            proxy.stop() // only one bridge at a time
            return await litellm.ensureRunning(port: settings.litellmPort,
                                               ollamaBaseURL: serverURL)
        }

        litellm.stop()
        let err = await proxy.ensureRunning(port: settings.routerPort,
                                            ollamaBaseURL: serverURL,
                                            numCtx: settings.ollamaNumCtx,
                                            think: settings.showReasoning,
                                            maxPredict: settings.ollamaMaxPredict)
        return err
    }

    /// The LiteLLM bridge (installed on demand into Application Support).
    let litellm = LiteLLMProcess()

    /// Port the active bridge listens on — used for keep-alive pings.
    func activeBridgePort(settings: AppSettings) -> Int {
        settings.bridgeEngine == .litellm ? settings.litellmPort : settings.routerPort
    }

    /// Liveness path of the active bridge (LiteLLM's `/health` is expensive).
    func activeBridgeHealthPath(settings: AppSettings) -> String {
        settings.bridgeEngine == .litellm ? "/health/liveliness" : "/health"
    }

    /// Is the active bridge's *process* alive? Unlike an HTTP probe this can't be
    /// confused by a bridge that is merely busy, so it's the one signal safe to
    /// trust mid-turn.
    func bridgeProcessAlive(settings: AppSettings) -> Bool {
        settings.bridgeEngine == .litellm ? litellm.isRunning : proxy.isRunning
    }

    /// Is the active bridge answering? Use this — never `OllamaClient.isReachable`,
    /// which probes Ollama's `/api/tags`; a bridge doesn't serve that, so it would
    /// always look dead and get needlessly restarted mid-turn.
    func bridgeHealthy(settings: AppSettings) async -> Bool {
        let port = activeBridgePort(settings: settings)
        let path = activeBridgeHealthPath(settings: settings)
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Start keep-alive pings for the current proxy port.  Call this when a model is selected.
    func startKeepAlive(port: Int, healthPath: String = "/health") {
        pinger.start(port: port, healthPath: healthPath)
    }

    /// Stop keep-alive pings.  Call when switching away from Ollama or clearing selection.
    func stopKeepAlive() {
        pinger.stop()
    }

    /// Check whether the proxy is currently healthy (nil = never pinged yet).
    var proxyHealth: Bool? { pinger.isHealthy }

    func shutdown() {
        pinger.stop()
        proxy.stop()
        litellm.stop()
    }

    /// Called on app quit: unload the models we loaded — each from its own
    /// server — then stop the router. Models stay resident (keep_alive:-1)
    /// while the app runs; this is the only place they're released.
    func cleanupOnQuit() {
        pinger.stop()
        for used in usedModels {
            unloadSync(model: used.model, baseURL: used.serverURL)
        }
        proxy.stop()
        litellm.stop()
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
