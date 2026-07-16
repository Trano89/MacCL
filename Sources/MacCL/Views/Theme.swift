import SwiftUI

/// Visual tokens tuned to feel close to the MacCL app — accent synced from UserDefaults.
enum Theme {
    /// Accent color read directly from UserDefaults so preference changes propagate everywhere.
    static var accent: Color {
        let hex = UserDefaults.standard.integer(forKey: "accentColorHex")
        guard hex != 0 else { return Color(red: 0.85, green: 0.46, blue: 0.34) }
        return Color(
            red: Double((hex & 0xFF0000) >> 16) / 255.0,
            green: Double((hex & 0x00FF00) >> 8) / 255.0,
            blue: Double(hex & 0x0000FF) / 255.0
        )
    }

    static var accentSoft: Color { accent.opacity(0.14) }

    static var userBubble: Color { Color.primary.opacity(0.06) }
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
