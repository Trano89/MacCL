import SwiftUI
import AppKit

/// Which appearance theme the user wants.
enum AppearanceTheme: String, CaseIterable {
    case system, light, dark

    @MainActor var label: String { L10n.t("theme_\(rawValue)") }

    /// The forced NSAppearance, or nil for "follow the system".
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - AppearanceCoordinator

/// The ONE owner of clair/sombre/automatique. Views change `theme`; every
/// window (current and future) follows, including the Settings window.
@MainActor
final class AppearanceCoordinator: ObservableObject {
    static let shared = AppearanceCoordinator()

    @Published var theme: AppearanceTheme {
        didSet {
            AppSettings.shared.appearanceThemeRaw = theme.rawValue
            apply()
        }
    }
    /// Accent color mirrored from AppSettings so views can observe one object.
    @Published var accentColor: Color

    private init() {
        theme = AppearanceTheme(rawValue: AppSettings.shared.appearanceThemeRaw) ?? .system
        accentColor = AppSettings.shared.accentColor
    }

    func accentChanged() {
        accentColor = AppSettings.shared.accentColor
    }

    /// Force (or release) the appearance for the WHOLE application in one move.
    /// `NSApp.appearance` is the canonical switch: unlike the old per-window
    /// loop it also covers sheets, popovers, menus, alerts, the Settings scene
    /// and every window opened later — which is why parts of the UI used to be
    /// left behind on clair ↔ sombre. `nil` = follow the system (automatique).
    func apply() {
        NSApp.appearance = theme.nsAppearance
    }
}
