import Foundation

/// The local bridge that translates Claude Code's Anthropic Messages API into
/// Ollama calls. Both speak `/v1/messages` on localhost; only the implementation
/// differs.
enum BridgeEngine: String, CaseIterable, Identifiable {
    /// The bundled Node proxy: no dependency, recovers tool calls that models
    /// emit as text, streams reasoning live, auto-grows num_ctx.
    case builtin
    /// LiteLLM (Python): the community's reference bridge, with strict network
    /// guard-rails — a good fit for a remote Ollama over a flaky link.
    case litellm

    var id: String { rawValue }

    @MainActor var label: String {
        switch self {
        case .builtin: return L10n.t("bridge_builtin")
        case .litellm: return "LiteLLM"
        }
    }

    @MainActor var explanation: String {
        switch self {
        case .builtin: return L10n.t("bridge_builtin_x")
        case .litellm: return L10n.t("bridge_litellm_x")
        }
    }
}
