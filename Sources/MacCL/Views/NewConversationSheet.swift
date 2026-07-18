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
    @State private var permission: PermissionMode = .bypassPermissions
    @State private var effort: EffortLevel = .high
    @State private var convInstructions = ""

    private var allModels: [LLMModel] { LLMModel.anthropicCatalog + serverModels }
    private var model: LLMModel? { allModels.first { $0.id == modelId } }

    /// What the typed address actually resolves to — `192.168.1.20` becomes
    /// `http://192.168.1.20:11434`. nil while the text can't be made into a
    /// server address. Everything downstream uses this, never the raw field.
    private var resolvedServerURL: String? { URLValidator.sanitizeAndValidate(serverURL) }

    var body: some View {
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
                            Text(displayPath(workingDirectory))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button(L10n.t("choose"), action: chooseFolder)
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
            permission = settings.permissionMode
            effort = settings.effortLevel
            convInstructions = vm.conversationInstructions
            Task { await scan() }
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

    private var commandPreview: String {
        guard let m = model else { return "" }
        // Same builders as the real spawn (SessionConfig + ModelRouter), so the
        // preview can never drift from what actually executes.
        var env = ""
        if m.provider != .anthropic {
            env = ModelRouter.shared
                .environment(for: m, serverURL: resolvedServerURL ?? serverURL)
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ") + " "
        }
        let config = SessionConfig(
            claudePath: "claude", workingDirectory: workingDirectory, model: m,
            permissionMode: permission, effort: effort,
            appendSystemPrompt: convInstructions,
            streamPartial: settings.streamPartialMessages, sessionId: "<uuid>")
        let cmd = "claude " + config.cliArguments(resume: false, forDisplay: true)
            .joined(separator: " ")
        // Two-step launch, like a human at a terminal: minimal command first,
        // then the session-level tuning sent as in-band slash commands.
        return "cd \"\(workingDirectory)\"\n\(env)\(cmd)\n> /effort \(effort.cliValue)"
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workingDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }

    private func start() {
        // Bind to the resolved address, never the raw text: the conversation must
        // record where it actually talks, not what happened to be typed.
        let server = resolvedServerURL ?? settings.ollamaBaseURL
        settings.selectedModelId = modelId
        settings.workingDirectory = workingDirectory
        settings.permissionMode = permission
        settings.effortLevel = effort
        settings.ollamaBaseURL = server             // seed for the next sheet
        vm.newConversation()
        vm.conversationServerURL = server           // this conversation's own server
        vm.conversationInstructions = convInstructions // after reset, applies to this conversation
        Task { await vm.refreshModels() }
        // Preload the chosen model while the user types their first message —
        // by send time the cold load is already paid (or well underway).
        if let m = model, m.provider != .anthropic {
            Task.detached { await OllamaClient.warmUp(model: m.modelArg, baseURL: server) }
        }
        dismiss()
    }
}
