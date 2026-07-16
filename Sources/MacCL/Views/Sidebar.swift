import SwiftUI

/// Minimal sidebar (Ollama-style): new conversation + history + status.
/// All launch parameters live in the composer bar.
struct Sidebar: View {
    @ObservedObject var vm: ChatViewModel
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var conversations = ConversationStore.shared
    @State private var showNewConversation = false

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: settings.language.rawValue)
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showNewConversation = true
            } label: {
                Label(L10n.t("new_conversation"), systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.accentColor)
            .controlSize(.large)
            .padding(12)
            .sheet(isPresented: $showNewConversation) {
                NewConversationSheet(vm: vm)
            }

            Divider()

            List {
                Section(L10n.t("history")) {
                    if conversations.summaries.isEmpty {
                        Text(L10n.t("no_conversation"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(conversations.summaries.prefix(40)) { summary in
                            let isActive = summary.id == vm.currentConversationId

                            Button {
                                vm.load(summary)
                            } label: {
                                HStack(spacing: 0) {
                                    Rectangle()
                                        .fill(isActive ? Theme.accent.opacity(0.45) : .clear)
                                        .frame(width: 3)
                                        .cornerRadius(1.5)
                                        .overlay(
                                            Rectangle()
                                                .stroke(Theme.accent.opacity(isActive ? 0.8 : 0), lineWidth: 1)
                                        )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(summary.title)
                                            .foregroundStyle(isActive ? .white : .primary)
                                            .lineLimit(1)
                                        Text(relativeDate(summary.updatedAt))
                                            .foregroundStyle(isActive ? Color.white.opacity(0.7) : .secondary)
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.corner)
                                        .fill(isActive ? Theme.accent.opacity(0.55) : Color.clear)
                                )
                                .contentShape(Rectangle())
                                .animation(.spring(response: 0.35, dampingFraction: 0.7, blendDuration: 0.2), value: isActive)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    vm.deleteConversation(summary)
                                } label: {
                                    Label(L10n.t("delete"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Circle()
                    .fill(vm.isRunning ? settings.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(vm.statusLine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.t("preferences"))
            }
            .padding(12)
        }
    }
}
