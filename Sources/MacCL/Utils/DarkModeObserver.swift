import SwiftUI
import AppKit

/// Which appearance theme the user wants.
enum AppearanceTheme: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "Système"
        case .light:  return "Clair"
        case .dark:   return "Sombre"
        }
    }
}

// MARK: - AppearanceCoordinator

@MainActor
final class AppearanceCoordinator: ObservableObject {
    static let shared = AppearanceCoordinator()

    @Published var theme: AppearanceTheme = .system
    /// Accent color read from AppSettings and propagated to all windows.
    @Published var accentColor: Color

    private init() {
        self.accentColor = AppSettings.shared.accentColor
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: nil)
    }

    @objc private func defaultsChanged() {
        let raw = UserDefaults.standard.string(forKey: "appearanceThemeRaw") ?? "system"
        let newTheme = AppearanceTheme(rawValue: raw) ?? .system
        if newTheme != theme {
            theme = newTheme
            applyAllWindowsAppearance()
        }
        let newAccent = AppSettings.shared.accentColor
        if newAccent != accentColor {
            accentColor = newAccent
        }
    }

    private func applyAllWindowsAppearance() {
        guard theme != .system else { return }
        let nsApp: NSAppearance?
        switch theme {
        case .light:  nsApp = NSAppearance(named: .aqua)
        case .dark:   nsApp = NSAppearance(named: .darkAqua)
        case .system: nsApp = nil
        }
        guard let appearance = nsApp else { return }
        for w in NSApplication.shared.windows where w.appearance !== appearance {
            w.appearance = appearance
        }
    }

    func applyTo(_ window: NSWindow?) {
        guard let w = window else { return }
        let nsApp: NSAppearance?
        switch theme {
        case .light:  nsApp = NSAppearance(named: .aqua)
        case .dark:   nsApp = NSAppearance(named: .darkAqua)
        case .system: nsApp = nil
        }
        guard let appearance = nsApp else { return }
        if w.appearance !== appearance { w.appearance = appearance }
    }
}
