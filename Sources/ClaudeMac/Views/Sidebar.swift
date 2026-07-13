import SwiftUI

/// Minimal sidebar (Ollama-style): new conversation + history + status.
/// All launch parameters live in the composer bar.
struct Sidebar: View {
    @ObservedObject var vm: ChatViewModel
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var conversations = ConversationStore.shared
    @State private var showNewConversation = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showNewConversation = true
            } label: {
                Label("Nouvelle conversation", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .padding(12)
            .sheet(isPresented: $showNewConversation) {
                NewConversationSheet(vm: vm)
            }

            Divider()

            List {
                Section("Historique") {
                    if conversations.summaries.isEmpty {
                        Text("Aucune conversation")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(conversations.summaries.prefix(40)) { summary in
                            Button {
                                vm.load(summary)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(summary.title)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Text(Self.relativeFormatter.localizedString(for: summary.updatedAt, relativeTo: Date()))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    vm.deleteConversation(summary)
                                } label: {
                                    Label("Supprimer", systemImage: "trash")
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
                    .fill(vm.isRunning ? Theme.accent : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(vm.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Préférences")
            }
            .padding(12)
        }
    }
}
