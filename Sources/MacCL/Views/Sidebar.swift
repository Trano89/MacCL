import SwiftUI

/// Minimal sidebar (Ollama-style): new conversation + history + status.
/// All launch parameters live in the composer bar.
struct Sidebar: View {
    @ObservedObject var vm: ChatViewModel
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var conversations = ConversationStore.shared
    @State private var showNewConversation = false
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var groupTarget: ConversationSummary?

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: settings.language.rawValue)
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private func historyRow(_ summary: ConversationSummary) -> some View {
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
            Menu(L10n.t("group")) {
                ForEach(conversations.groupNames, id: \.self) { group in
                    Button {
                        vm.assignGroup(summary, group: group)
                    } label: {
                        if summary.group == group {
                            Label(group, systemImage: "checkmark")
                        } else {
                            Text(group)
                        }
                    }
                }
                if !conversations.groupNames.isEmpty { Divider() }
                Button("\(L10n.t("new_group"))…") {
                    groupTarget = summary
                    showNewGroup = true
                }
                if summary.group != nil {
                    Button(L10n.t("no_group")) {
                        vm.assignGroup(summary, group: nil)
                    }
                }
            }
            Button(role: .destructive) {
                vm.deleteConversation(summary)
            } label: {
                Label(L10n.t("delete"), systemImage: "trash")
            }
        }
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
                // Ungrouped conversations first, then one section per custom group.
                Section(L10n.t("history")) {
                    let ungrouped = conversations.summaries.filter { $0.group == nil }
                    if conversations.summaries.isEmpty {
                        Text(L10n.t("no_conversation"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ungrouped.prefix(40)) { summary in
                            historyRow(summary)
                        }
                    }
                }
                ForEach(conversations.groupNames, id: \.self) { group in
                    Section(group) {
                        ForEach(conversations.summaries.filter { $0.group == group }) { summary in
                            historyRow(summary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .alert(L10n.t("new_group"), isPresented: $showNewGroup) {
                TextField(L10n.t("group_name"), text: $newGroupName)
                Button(L10n.t("new_group")) {
                    if let target = groupTarget, !newGroupName.trimmingCharacters(in: .whitespaces).isEmpty {
                        vm.assignGroup(target, group: newGroupName)
                    }
                    newGroupName = ""
                    groupTarget = nil
                }
                Button(L10n.t("cancel"), role: .cancel) {
                    newGroupName = ""
                    groupTarget = nil
                }
            }

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
