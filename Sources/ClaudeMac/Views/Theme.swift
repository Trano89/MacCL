import SwiftUI

/// Visual tokens tuned to feel close to the Claude app: warm coral accent,
/// generous whitespace, a centered reading column.
enum Theme {
    /// Claude's signature coral / terracotta.
    static let accent = Color(red: 0.85, green: 0.46, blue: 0.34)
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
