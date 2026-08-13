import SwiftUI
import AppKit

/// Launch sheet for a new conversation — the GUI equivalent of typing the
/// `claude` command in a terminal: pick the Ollama SERVER, the LLM, the
/// working directory, the permission mode and the effort. These become the
/// conversation's own parameters (persisted with it, restored when reopened).
/// The server is asked HERE, every time: each conversation is bound to its own.
struct NewConversationSheet: View {
    @ObservedObject var vm: ChatViewModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = ""
    @State private var discovered: [OllamaDiscovery.Server] = []
    @State private var scanning = false
    @State private var serverModels: [LLMModel] = []
    @State private var loadingModels = false
    @State private var modelId = ""
    @State private var workingDirectory = ""
    /// "" = this Mac, otherwise the id of the SSHHost the folder lives on.
    @State private var workHostId = ""
    @State private var showWorkLocation = false
    @State private var permission: PermissionMode = .bypassPermissions
    @State private var effort: EffortLevel = .high
    @State private var convInstructions = ""
    /// `model` or `model@machine`; empty = sub-agents use the conversation's model.
    @State private var subagentModel = ""
    /// Model names of the saved machines other than this conversation's server.
    @State private var otherMachines: [MachineModels] = []

    struct MachineModels {
        let server: StandbyServer
        let models: [String]
        var label: String { server.name.isEmpty ? server.displayHost : server.name }
    }

    private var allModels: [LLMModel] { LLMModel.anthropicCatalog + serverModels }
    private var model: LLMModel? { allModels.first { $0.id == modelId } }

    /// What the typed address actually resolves to — `192.168.1.20` becomes
    /// `http://192.168.1.20:11434`. nil while the text can't be made into a
    /// server address. Everything downstream uses this, never the raw field.
    private var resolvedServerURL: String? { URLValidator.sanitizeAndValidate(serverURL) }

    /// The machine the working folder lives on, nil when it's this Mac.
    private var workHost: SSHHost? { SSHHostStore.shared.host(id: workHostId) }

    var body: some View {
        // The location picker is a MODE, not a nested sheet — same reason as
        // ServerPickerSheet's model manager: sheets over sheets have misbehaved
        // in this app before.
        if showWorkLocation {
            WorkLocationSheet(initial: WorkLocation(hostId: workHostId, path: workingDirectory)) { location in
                if let location {
                    workingDirectory = location.path
                    workHostId = location.hostId
                }
                showWorkLocation = false
            }
        } else {
            launchForm
        }
    }

    private var launchForm: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.t("new_conversation"), systemImage: "terminal")
                    .font(.title3.bold())
                Spacer()
            }
            .padding(14)
            Divider()

            Form {
                serverSection

                Section(L10n.t("launch_params")) {
                    Picker(L10n.t("model_llm"), selection: $modelId) {
                        Section("Anthropic") {
                            ForEach(LLMModel.anthropicCatalog) { m in
                                Text(m.name).tag(m.id)
                            }
                        }
                        if loadingModels {
                            Text(L10n.t("loading_models")).tag("__loading__")
                        } else if !serverModels.isEmpty {
                            Section("Ollama · \(serverHostLabel)") {
                                ForEach(serverModels) { m in
                                    Text(m.name).tag(m.id)
                                }
                            }
                        }
                    }
                    LabeledContent(L10n.t("folder_help")) {
                        HStack(spacing: 8) {
                            if let host = workHost {
                                Label(host.label, systemImage: "network")
                                    .font(.caption)
                                    .foregroundStyle(Theme.accent)
                            }
                            Text(displayPath(workingDirectory))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button(L10n.t("choose")) { showWorkLocation = true }
                        }
                    }
                    // Which brain the delegated work uses — a conversation-wide
                    // choice, because the agents that actually run are the ones
                    // Claude Code spawns itself, not files anyone authored.
                    Picker(L10n.t("model_for_subagents"), selection: $subagentModel) {
                        Text(L10n.t("subagent_inherit")).tag("")
                        if !serverModels.isEmpty {
                            Section(serverHostLabel) {
                                ForEach(serverModels) { m in
                                    Text(m.name).tag(m.modelArg)
                                }
                            }
                        }
                        ForEach(otherMachines, id: \.server.id) { entry in
                            Section(entry.label) {
                                ForEach(entry.models, id: \.self) { name in
                                    Text(name)
                                        .tag(name + AgentDefinition.serverSeparator
                                             + entry.server.name)
                                }
                            }
                        }
                    }
                    Picker(L10n.t("permissions"), selection: $permission) {
                        ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                    }
                    Picker(L10n.t("effort"), selection: $effort) {
                        ForEach(EffortLevel.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section(L10n.t("conv_instructions")) {
                    TextEditor(text: $convInstructions)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 100)
                }

                Section(L10n.t("equivalent_cmd")) {
                    Text(verbatim: commandPreview)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L10n.t("cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("start")) { start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 580, height: 560)
        .onAppear {
            serverURL = settings.ollamaBaseURL     // last used, as a default
            modelId = settings.selectedModelId
            workingDirectory = settings.workingDirectory
            workHostId = settings.workLocationHostId
            permission = settings.permissionMode
            effort = settings.effortLevel
            convInstructions = vm.conversationInstructions
            subagentModel = settings.subagentModel
            Task { await scan() }
            Task { await loadOtherMachines() }
        }
        // Keyed task: each edit cancels the previous lookup, so a slow reply from
        // the address you just replaced can't overwrite the current one's models.
        .task(id: serverURL) {
            try? await Task.sleep(nanoseconds: 350_000_000)   // settle while typing
            guard !Task.isCancelled else { return }
            await loadModels()
        }
    }

    /// Per-conversation server: discovered machines + manual entry.
    private var serverSection: some View {
        Section(L10n.t("conv_server")) {
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
                Button {
                    Task { await scan() }
                } label: {
                    if scanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L10n.t("scan"), systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(scanning)
            }
            Text(L10n.t("server_entry_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
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
            if !loadingModels && serverModels.isEmpty {
                Label(L10n.t("server_no_models_hint"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var serverHostLabel: String {
        URL(string: serverURL)?.host ?? serverURL
    }

    private func scan() async {
        scanning = true
        discovered = await OllamaDiscovery.discover(port: URLValidator.defaultOllamaPort,
                                                    configured: resolvedServerURL ?? "")
        scanning = false
    }

    private func loadModels() async {
        guard let url = resolvedServerURL else { serverModels = []; return }
        loadingModels = true
        let models = await OllamaClient.listModels(baseURL: url)
        guard !Task.isCancelled else { return }   // a newer keystroke owns the field now
        serverModels = models
        loadingModels = false
        // Keep the selection valid for THIS server.
        if !allModels.contains(where: { $0.id == modelId }) {
            modelId = serverModels.first?.id ?? LLMModel.anthropicCatalog.first?.id ?? "anthropic:opus"
        }
    }

    /// Models on the OTHER saved machines, so a sub-agent can be sent to one
    /// without leaving this sheet. Machines that don't answer contribute
    /// nothing rather than holding the form up.
    private func loadOtherMachines() async {
        var found: [MachineModels] = []
        for server in settings.standbyServers where !server.name.isEmpty {
            guard server.url != resolvedServerURL else { continue }
            let models = await OllamaClient.listModels(baseURL: server.url)
            if !models.isEmpty {
                found.append(MachineModels(server: server, models: models.map(\.modelArg).sorted()))
            }
        }
        otherMachines = found
    }

    private var commandPreview: String {
        guard let m = model else { return "" }
        // Same builders as the real spawn (SessionConfig + ModelRouter), so the
        // preview can never drift from what actually executes — including the
        // ssh hop and the reverse tunnel when the folder is on another machine.
        let server = resolvedServerURL ?? serverURL
        var env = m.provider == .anthropic
            ? [:] : ModelRouter.shared.environment(for: m, serverURL: server)
        // Same variable the real launch sets: the delegated work's brain is part
        // of what this command does, so the preview has to admit it.
        if !subagentModel.isEmpty { env["CLAUDE_CODE_SUBAGENT_MODEL"] = subagentModel }
        let host = workHost
        var tunnel: [String] = []
        if host != nil, m.provider != .anthropic,
           let t = SSHClient.reverseTunnel(forServerURL: server) {
            tunnel = t.options
        }
        let config = SessionConfig(
            claudePath: "claude", workingDirectory: workingDirectory,
            remoteHost: host, model: m,
            permissionMode: permission, effort: effort,
            appendSystemPrompt: convInstructions,
            streamPartial: settings.streamPartialMessages, sessionId: "<uuid>",
            maxOutputTokens: settings.maxOutputTokens,
            extraEnv: env, reverseTunnelOptions: tunnel)
        return SessionConfig.displayCommand(config: config, resumed: false)
    }

    /// `~` shorthand only makes sense for a path on THIS Mac — a remote home
    /// isn't this one, so remote paths are shown in full.
    private func displayPath(_ path: String) -> String {
        guard workHost == nil else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func start() {
        // Bind to the resolved address, never the raw text: the conversation must
        // record where it actually talks, not what happened to be typed.
        let server = resolvedServerURL ?? settings.ollamaBaseURL
        settings.selectedModelId = modelId
        settings.workLocation = WorkLocation(hostId: workHostId, path: workingDirectory)
        settings.permissionMode = permission
        settings.effortLevel = effort
        settings.ollamaBaseURL = server             // seed for the next sheet
        vm.newConversation()
        vm.conversationServerURL = server           // this conversation's own server
        vm.conversationInstructions = convInstructions // after reset, applies to this conversation
        vm.subagentModel = subagentModel            // which brain the delegated work uses
        settings.subagentModel = subagentModel      // seed for the next sheet
        Task { await vm.refreshModels() }
        // Preload the chosen model while the user types their first message —
        // by send time the cold load is already paid (or well underway).
        if let m = model, m.provider != .anthropic {
            Task.detached { await OllamaClient.warmUp(model: m.modelArg, baseURL: server) }
        }
        dismiss()
    }
}
