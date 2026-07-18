import SwiftUI

/// Visual tokens shared by every view. Semantic, adaptive by construction:
/// everything derives from `Color.primary` or the accent, so clair, sombre et
/// automatique come out right without a single hard-coded light/dark pair.
@MainActor
enum Theme {
    /// The user's accent — read from the single source of truth (AppSettings),
    /// not from a parallel UserDefaults lookup that could drift from it.
    static var accent: Color { AppSettings.shared.accentColor }

    static var accentSoft: Color { accent.opacity(0.14) }

    static var userBubble: Color { accent.opacity(0.10) }
    static var card: Color { Color.primary.opacity(0.035) }
    static var hairline: Color { Color.primary.opacity(0.09) }

    static let corner: CGFloat = 14
    static let contentMaxWidth: CGFloat = 740
}

extension View {
    /// Constrain content to the centered reading column.
    func readingColumn() -> some View {
        frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
