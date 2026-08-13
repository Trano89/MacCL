import SwiftUI

/// Model chooser presented as a sheet — for the conversation, and for the
/// sub-agents it delegates to.
///
/// Both live here on purpose. "Which brain thinks" is one question asked twice,
/// and the delegated half used to be answered by authoring files describing
/// agents that Claude Code mostly doesn't spawn — which explained nothing about
/// what actually ran on the machine.
struct ModelPickerSheet: View {
    @ObservedObject var vm: ChatViewModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    /// 0 = the conversation's model, 1 = its sub-agents'.
    var initialTarget: Int = 0

    @State private var target = 0
    /// Model names per standby server URL, fetched as the sheet opens so a
    /// sub-agent can only be sent to a model that machine actually has.
    @State private var modelsByURL: [String: [String]] = [:]

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

            Picker("", selection: $target) {
                Text(L10n.t("model_for_conversation")).tag(0)
                Text(L10n.t("model_for_subagents")).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            Divider()

            if target == 0 {
                List {
                    buildModelList(groups: Dictionary(grouping: vm.availableModels,
                                                      by: { $0.provider }))
                }
            } else {
                subagentList
            }

            Divider()
            HStack {
                Spacer()
                Button(L10n.t("close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(width: 420, height: 500)
        .onAppear { target = initialTarget }
        .task { await loadStandbyModels() }
    }

    // MARK: Sub-agent model

    private var subagentList: some View {
        List {
            Section {
                subagentRow(label: L10n.t("subagent_inherit"), value: "",
                            detail: vm.selectedModel.name)
            } footer: {
                Text(L10n.t("subagent_model_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // How many at once belongs beside which brain: together they decide
            // how much a single Ollama box is being asked to hold at a time.
            Section(L10n.t("concurrency_title")) {
                Stepper(value: $settings.maxConcurrentSubagents, in: 1...20) {
                    Text(settings.maxConcurrentSubagents == 1
                         ? L10n.t("concurrency_serial")
                         : "\(settings.maxConcurrentSubagents)")
                        .monospacedDigit()
                }
                if !settings.standbyServers.isEmpty {
                    Stepper(value: $settings.maxConcurrentPerServer, in: 1...20) {
                        HStack {
                            Text(L10n.t("concurrency_per_server"))
                            Spacer()
                            Text("\(settings.maxConcurrentPerServer)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(L10n.t("concurrency_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The conversation's own server: no suffix, so no router involved.
            let local = vm.availableModels.filter { $0.provider != .anthropic }
            if !local.isEmpty {
                Section(vm.serverHost) {
                    ForEach(local) { model in
                        subagentRow(label: model.name, value: model.modelArg,
                                    detail: model.subtitle)
                    }
                }
            }

            // Other machines: the value carries the `@machine` suffix the
            // router dispatches on.
            ForEach(settings.standbyServers) { server in
                let names = modelsByURL[server.url] ?? []
                if !names.isEmpty, server.url != vm.conversationServerURL {
                    Section(server.name.isEmpty ? server.displayHost : server.name) {
                        ForEach(names, id: \.self) { name in
                            subagentRow(label: name,
                                        value: name + AgentDefinition.serverSeparator
                                             + server.name,
                                        detail: server.displayHost)
                        }
                    }
                }
            }
        }
    }

    private func subagentRow(label: String, value: String, detail: String?) -> some View {
        let selected = vm.subagentModel == value
        return Button {
            vm.subagentModel = value
            settings.subagentModel = value   // seed for the next conversation
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                    if let detail, !detail.isEmpty {
                        Text(detail).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One listing per saved machine. Servers that don't answer simply
    /// contribute nothing rather than blocking the sheet.
    private func loadStandbyModels() async {
        for server in settings.standbyServers where modelsByURL[server.url] == nil {
            guard !server.name.isEmpty, server.url != vm.conversationServerURL else { continue }
            let models = await OllamaClient.listModels(baseURL: server.url)
            modelsByURL[server.url] = models.map(\.modelArg).sorted()
        }
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
