import Foundation

/// A model the user can pick from the model selector.
struct LLMModel: Identifiable, Hashable {
    enum Provider: String, Codable {
        case anthropic
        case ollama
        case ollamaNetwork

        var label: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .ollama: return "Ollama · local"
            case .ollamaNetwork: return "Ollama · réseau"
            }
        }
    }

    let id: String          // stable id, e.g. "anthropic:opus" or "ollamaNet:some-server/qwen3-coder"
    let provider: Provider
    let name: String        // display name
    /// The model identifier passed to the backend.
    let modelArg: String
    /// Friendly server name shown as subtitle for network servers.
    var serverName: String?
    var subtitle: String?

    static let anthropicCatalog: [LLMModel] = [
        LLMModel(id: "anthropic:opus", provider: .anthropic, name: "Claude Opus 4.8",
                 modelArg: "opus", subtitle: "Le plus capable"),
        LLMModel(id: "anthropic:sonnet", provider: .anthropic, name: "Claude Sonnet 5",
                 modelArg: "sonnet", subtitle: "Équilibré"),
        LLMModel(id: "anthropic:haiku", provider: .anthropic, name: "Claude Haiku 4.5",
                 modelArg: "haiku", subtitle: "Rapide et économique"),
        LLMModel(id: "anthropic:fable", provider: .anthropic, name: "Claude Fable 5",
                 modelArg: "fable", subtitle: "Créatif"),
    ]

    static var ollamaNetworkCatalog: [LLMModel] = [] // populated at runtime

    static func registerNetworkModels(_ models: [LLMModel]) {
        ollamaNetworkCatalog = models.filter { $0.provider == .ollamaNetwork }
    }

    /// Heuristic: a large local model that may be slow / memory-heavy to load.
    /// Uses `modelArg` (which for Ollama equals the model name).
    var isHeavyLocal: Bool {
        guard provider == .ollama else { return false }
        let n = modelArg.lowercased()
        // Match parameter suffixes (70b, 72b, etc.) in the model name.
        return n.range(of: " 70b$| 72b$| 65b$| 34b$| 32b$| 30b$| 27b$| 26b$| 24b$| 22b$", options: .regularExpression) != nil
    }

    /// Build an Ollama entry from a model name reported by `/api/tags`.
    static func ollama(_ name: String, capabilities: [String] = []) -> LLMModel {
        var subtitle = "local"
        if capabilities.contains("tools") { subtitle += " · outils" }
        if capabilities.contains("vision") { subtitle += " · vision" }
        return LLMModel(id: "ollama:\(name)", provider: .ollama, name: name,
                        modelArg: name, subtitle: subtitle)
    }
}

/// Claude Code permission modes exposed in the UI.
enum PermissionMode: String, CaseIterable, Identifiable {
    case bypassPermissions
    case acceptEdits
    case plan
    case defaultMode

    var id: String { rawValue }

    /// Value passed to `claude --permission-mode`.
    var cliValue: String {
        switch self {
        case .defaultMode: return "default"
        default: return rawValue
        }
    }

    @MainActor var label: String {
        switch self {
        case .bypassPermissions: return L10n.t("perm_bypass")
        case .acceptEdits: return L10n.t("perm_accept")
        case .plan: return L10n.t("perm_plan")
        case .defaultMode: return L10n.t("perm_default")
        }
    }

    @MainActor var explanation: String {
        switch self {
        case .bypassPermissions: return L10n.t("perm_bypass_x")
        case .acceptEdits: return L10n.t("perm_accept_x")
        case .plan: return L10n.t("perm_plan_x")
        case .defaultMode: return L10n.t("perm_default_x")
        }
    }
}
