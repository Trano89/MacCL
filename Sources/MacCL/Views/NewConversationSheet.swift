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
            Task { await loadModels() }
        }
        .onChange(of: serverURL) { _, _ in
            Task { await loadModels() }
        }
    }

    /// Per-conversation server: discovered machines + manual entry.
    private var serverSection: some View {
        Section(L10n.t("conv_server")) {
            HStack(spacing: 8) {
                TextField("http://192.168.1.10:11434", text: $serverURL)
                    .font(.system(.body, design: .monospaced))
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
        discovered = await OllamaDiscovery.discover(port: 11434, configured: serverURL)
        scanning = false
    }

    private func loadModels() async {
        loadingModels = true
        serverModels = await OllamaClient.listModels(baseURL: serverURL)
        loadingModels = false
        // Keep the selection valid for THIS server.
        if !allModels.contains(where: { $0.id == modelId }) {
            modelId = serverModels.first?.id ?? LLMModel.anthropicCatalog.first!.id
        }
    }

    private var commandPreview: String {
        let m = model
        var env = ""
        if m?.provider == .ollama {
            env = "ANTHROPIC_BASE_URL=\(settings.routerBaseURL) ANTHROPIC_MODEL=\(m?.modelArg ?? "?") "
            env = "# pont → \(serverURL)\n" + env
        }
        var cmd = "claude -p --input-format stream-json --output-format stream-json --verbose"
        cmd += " --model \(m?.modelArg ?? "?")"
        cmd += " --permission-mode \(permission.cliValue)"
        cmd += " --effort \(effort.cliValue)"
        if settings.streamPartialMessages { cmd += " --include-partial-messages" }
        return "cd \"\(workingDirectory)\"\n\(env)\(cmd)"
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
        settings.selectedModelId = modelId
        settings.workingDirectory = workingDirectory
        settings.permissionMode = permission
        settings.effortLevel = effort
        settings.ollamaBaseURL = serverURL          // seed for the next sheet
        vm.newConversation()
        vm.conversationServerURL = serverURL        // this conversation's own server
        vm.conversationInstructions = convInstructions // after reset, applies to this conversation
        Task { await vm.refreshModels() }
        dismiss()
    }
}
