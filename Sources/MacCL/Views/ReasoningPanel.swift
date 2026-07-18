import SwiftUI

/// A framed, collapsible panel that shows the model's reasoning for the current
/// turn — pinned under the transcript (i.e. under the last message).
struct ReasoningPanel: View {
    let text: String
    var isLive: Bool
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .foregroundStyle(Theme.accent)
                    Text(L10n.t("reasoning"))
                        .font(.body.weight(.semibold))
                    if isLive {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                ScrollView {
                    Text(text)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 220)
            }
        }
        .background(Theme.accentSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.30)))
    }
}
