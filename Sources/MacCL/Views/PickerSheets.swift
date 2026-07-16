import SwiftUI

/// Model chooser presented as a sheet (grouped Anthropic / Ollama).
struct ModelPickerSheet: View {
    @ObservedObject var vm: ChatViewModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.t("model_llm"), systemImage: "cpu")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await vm.refreshModels() }
                } label: {
                    Label(L10n.t("refresh"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            .padding(12)
            Divider()

            List {
                buildModelList(groups: Dictionary(grouping: vm.availableModels, by: { $0.provider }))
            }

            Divider()
            HStack {
                Spacer()
                Button(L10n.t("close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(width: 380, height: 460)
    }

    @ViewBuilder
    private func buildModelList(groups: [LLMModel.Provider: [LLMModel]]) -> some View {
        ForEach([LLMModel.Provider.anthropic, .ollama, .ollamaNetwork], id: \.self) { provider in
            if let models = groups[provider], !models.isEmpty {
                Section(provider.label) {
                    ForEach(models) { model in
                        Button {
                            settings.selectedModelId = model.id
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: model.id == settings.selectedModelId
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.id == settings.selectedModelId
                                                     ? Theme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.name)
                                    if let server = model.serverName {
                                        Text(server)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let sub = model.subtitle {
                                        Text(sub)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Claude Code slash-command list presented as a sheet; picking one inserts it
/// into the composer.
struct SlashCommandsSheet: View {
    let commands: [String]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.t("commands_help"), systemImage: "slash.circle")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            List(commands, id: \.self) { cmd in
                Button {
                    onPick(cmd)
                    dismiss()
                } label: {
                    Text("/" + cmd)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()
            HStack {
                Spacer()
                Button(L10n.t("close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(width: 320, height: 420)
    }
}
