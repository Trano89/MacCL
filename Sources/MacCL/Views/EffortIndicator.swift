import SwiftUI

/// A small rising-bars gauge that visualises the current effort level.
struct EffortIndicator: View {
    @EnvironmentObject var settings: AppSettings
    let level: EffortLevel
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .bottom, spacing: compact ? 1.5 : 2) {
            ForEach(1...5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= level.bars ? settings.accentColor : Color.secondary.opacity(0.28))
                    .frame(width: compact ? 2.5 : 3.5,
                           height: 3 + CGFloat(i) * (compact ? 1.6 : 2.4))
            }
        }
        .accessibilityLabel("Effort : \(level.label)")
        .animation(.easeOut(duration: 0.15), value: level)
    }
}
