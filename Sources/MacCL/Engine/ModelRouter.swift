import Foundation

/// Computes the environment that points `claude` at the right backend for a
/// given model.
///
/// - Anthropic models: no override — `claude` uses its own auth.
/// - Ollama models: `claude` talks **straight to the conversation's own Ollama
///   server**. Since v0.14, Ollama implements the Anthropic Messages API itself
///   (`POST /v1/messages`, streaming + tools + thinking + base64 images), so the
///   translation layer this app used to spawn is gone: no Node process, no port,
///   no health probe, no keep-alive pinger. An address is just an address —
///   localhost and a machine on the LAN take the exact same code path.
///
/// Two knobs that used to be per-request in the old bridge are now **server-side**
/// environment variables on the Ollama host, because the Messages API has no field
/// for them: `OLLAMA_CONTEXT_LENGTH` (KV-cache size — the RAM knob) and
/// `OLLAMA_KEEP_ALIVE` (how long a model stays resident).
@MainActor
final class ModelRouter {
    static let shared = ModelRouter()

    /// Environment overrides for the child `claude` process.
    /// Identical for every Ollama server — the conversation's server URL goes in
    /// verbatim, so a request can never silently land on another machine.
    func environment(for model: LLMModel, serverURL: String) -> [String: String] {
        switch model.provider {
        case .anthropic:
            return [:]
        case .ollama, .ollamaNetwork:
            // Exactly the two variables Ollama's own doc requires — the session's
            // identity, nothing else. App-level tuning (timeouts, output caps,
            // nonessential-traffic kill switch) is applied by ClaudeSession.spawn
            // and doesn't belong in the displayed command.
            // Deliberately absent:
            // - ANTHROPIC_MODEL: redundant, `--model` is already passed.
            // - ANTHROPIC_SMALL_FAST_MODEL: pointing it at the same model sent
            //   background calls to the conversation's model, wiping its cache.
            // - MAX_THINKING_TOKENS=0: measured ineffective — claude then omits
            //   the thinking field, and Ollama runs the model's default thinking
            //   anyway (budget_tokens isn't enforced either).
            return [
                "ANTHROPIC_BASE_URL": serverURL.trimmingTrailingSlash,
                "ANTHROPIC_AUTH_TOKEN": "ollama",
            ]
        }
    }

    /// Check the conversation's server is usable before we commit a turn to it.
    /// Returns nil when ready, else a message explaining what to fix.
    func prepare(for model: LLMModel, settings: AppSettings, serverURL: String) async -> String? {
        guard model.provider == .ollama || model.provider == .ollamaNetwork else { return nil }

        // Same validation for every server, localhost included.
        guard URLValidator.validate(serverURL) != nil else {
            return L10n.t("invalid_ollama_url")
        }
        guard await OllamaClient.isReachable(baseURL: serverURL) else {
            return L10n.t("ollama_unreachable", serverURL)
        }
        // A pre-0.14 server has no /v1/messages: every request would fail as an
        // opaque transport error and `claude` would just retry for a minute. Say
        // so plainly instead.
        if let version = await OllamaClient.version(baseURL: serverURL),
           !OllamaClient.supportsAnthropicAPI(version: version) {
            return L10n.t("ollama_too_old", version)
        }
        // Start loading the model NOW, in parallel with the turn — don't await:
        // the send must not wait minutes for a cold 30B when API_TIMEOUT_MS
        // already lets the turn survive the load.
        let modelArg = model.modelArg
        Task.detached { await OllamaClient.warmUp(model: modelArg, baseURL: serverURL) }
        return nil
    }

    /// Is the conversation's server answering? Without a bridge in the way this is
    /// simply Ollama's own liveness — the thing we actually care about.
    func serverReachable(_ serverURL: String) async -> Bool {
        await OllamaClient.isReachable(baseURL: serverURL)
    }
}

extension String {
    var trimmingTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
