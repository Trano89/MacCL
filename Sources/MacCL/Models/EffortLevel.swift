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

    @MainActor var label: String {
        switch self {
        case .low: return L10n.t("effort_low")
        case .medium: return L10n.t("effort_medium")
        case .high: return L10n.t("effort_high")
        case .xhigh: return L10n.t("effort_xhigh")
        case .max: return L10n.t("effort_max")
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

    @MainActor var explanation: String {
        switch self {
        case .low: return L10n.t("effort_low_x")
        case .medium: return L10n.t("effort_medium_x")
        case .high: return L10n.t("effort_high_x")
        case .xhigh: return L10n.t("effort_xhigh_x")
        case .max: return L10n.t("effort_max_x")
        }
    }
}
