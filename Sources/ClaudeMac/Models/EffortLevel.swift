import Foundation

/// Reasoning effort for the session, mapped to `claude --effort <level>`.
/// Higher effort = more thinking = better quality but slower / more costly.
enum EffortLevel: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    /// Value passed to `claude --effort`.
    var cliValue: String { rawValue }

    var label: String {
        switch self {
        case .low: return "Faible"
        case .medium: return "Moyen"
        case .high: return "Élevé"
        case .xhigh: return "Très élevé"
        case .max: return "Maximum"
        }
    }

    /// Filled bars in the effort gauge (1…5).
    var bars: Int {
        switch self {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .xhigh: return 4
        case .max: return 5
        }
    }

    var explanation: String {
        switch self {
        case .low: return "Réponses rapides, raisonnement minimal — le plus économique."
        case .medium: return "Équilibre entre vitesse et réflexion."
        case .high: return "Plus de réflexion, meilleure qualité (recommandé)."
        case .xhigh: return "Raisonnement approfondi — plus lent et plus coûteux."
        case .max: return "Effort maximal — le plus lent et le plus coûteux."
        }
    }
}
