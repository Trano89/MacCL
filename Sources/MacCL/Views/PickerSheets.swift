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
                                    // Subtitle already carries the server host.
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

/// Change the CURRENT conversation's Ollama server, mid-course. The claude
/// session survives: it resends the full history each turn, so the next
/// message replays the whole conversation on the new server.
struct ServerPickerSheet: View {
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = ""
    @State private var discovered: [OllamaDiscovery.Server] = []
    @State private var scanning = false
    /// Model management lives INSIDE this sheet as a mode — nested sheets have
    /// bitten this app before.
    @State private var managingModels = false

    /// What the typed address resolves to — `192.168.1.20` → `http://192.168.1.20:11434`.
    private var resolvedServerURL: String? { URLValidator.sanitizeAndValidate(serverURL) }

    var body: some View {
        if managingModels {
            ModelManagerView(serverURL: resolvedServerURL ?? vm.conversationServerURL) {
                managingModels = false
            }
        } else {
            pickerBody
        }
    }

    private var pickerBody: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.t("conv_server"), systemImage: "server.rack")
                    .font(.headline)
                Spacer()
                Button {
                    managingModels = true
                } label: {
                    Label(L10n.t("manage_models"), systemImage: "wrench.and.screwdriver")
                }
                .controlSize(.small)
                Button {
                    Task { await scan() }
                } label: {
                    if scanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L10n.t("scan"), systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .controlSize(.small)
                .disabled(scanning)
            }
            .padding(12)
            Divider()

            List {
                Section {
                    HStack(spacing: 8) {
                        TextField("192.168.1.10", text: $serverURL)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit { if let r = resolvedServerURL { serverURL = r } }
                        if !serverURL.isEmpty {
                            Image(systemName: resolvedServerURL == nil
                                  ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(resolvedServerURL == nil ? .orange : .green)
                                .help(resolvedServerURL ?? L10n.t("invalid_ollama_url"))
                        }
                    }
                    Text(L10n.t("server_entry_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !discovered.isEmpty {
                    Section(L10n.t("discovered_servers")) {
                        ForEach(discovered) { server in
                            Button {
                                serverURL = server.url
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: serverURL == server.url
                                          ? "checkmark.circle.fill" : "server.rack")
                                        .foregroundStyle(serverURL == server.url ? Theme.accent : .secondary)
                                    Text(server.host)
                                    Text("\(server.modelCount) \(L10n.t("models_count"))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    Text(L10n.t("server_change_note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack {
                Spacer()
                Button(L10n.t("cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("apply")) {
                    guard let url = resolvedServerURL else { return }
                    Task { await vm.changeServer(to: url) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(vm.isRunning || resolvedServerURL == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 420, height: 380)
        .onAppear {
            serverURL = vm.conversationServerURL
            Task { await scan() }
        }
    }

    private func scan() async {
        scanning = true
        discovered = await OllamaDiscovery.discover(port: 11434, configured: vm.conversationServerURL)
        scanning = false
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
