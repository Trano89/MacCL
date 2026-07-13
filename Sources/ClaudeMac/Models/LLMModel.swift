import Foundation

/// A model the user can pick from the model selector.
struct LLMModel: Identifiable, Hashable {
    enum Provider: String, Codable {
        case anthropic
        case ollama

        var label: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .ollama: return "Ollama · local"
            }
        }
    }

    let id: String          // stable id, e.g. "anthropic:opus" or "ollama:qwen3-coder:30b"
    let provider: Provider
    let name: String        // display name
    /// Value passed to `claude --model` (Anthropic) or `ANTHROPIC_MODEL` (routed local).
    let modelArg: String
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

    /// Heuristic: a large local model that may be slow / memory-heavy to load.
    var isHeavyLocal: Bool {
        guard provider == .ollama else { return false }
        let n = name.lowercased()
        return ["70b", "72b", "65b", "34b", "32b", "30b", "27b", "26b", "24b", "22b"]
            .contains { n.contains($0) }
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

    var label: String {
        switch self {
        case .bypassPermissions: return "Tous les outils (bypass)"
        case .acceptEdits: return "Éditions auto"
        case .plan: return "Mode plan"
        case .defaultMode: return "Demander (défaut)"
        }
    }

    var explanation: String {
        switch self {
        case .bypassPermissions: return "Tous les outils s'exécutent sans confirmation. Pratique, mais l'agent peut lancer n'importe quelle commande."
        case .acceptEdits: return "Les modifications de fichiers sont acceptées automatiquement ; les autres outils sont refusés tant que le dialogue natif n'est pas branché."
        case .plan: return "L'agent planifie sans rien exécuter."
        case .defaultMode: return "Sans le dialogue de permission natif, les outils non autorisés sont refusés."
        }
    }
}
