import SwiftUI
import AppKit

/// Launch sheet for a new conversation — the GUI equivalent of typing the
/// `claude` command in a terminal: pick the LLM, the working directory, the
/// permission mode and the effort. These become the conversation's own
/// parameters (persisted with it, restored when it's reopened).
struct NewConversationSheet: View {
    @ObservedObject var vm: ChatViewModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var modelId = ""
    @State private var workingDirectory = ""
    @State private var permission: PermissionMode = .bypassPermissions
    @State private var effort: EffortLevel = .high

    private var model: LLMModel? { vm.availableModels.first { $0.id == modelId } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Nouvelle conversation", systemImage: "terminal")
                    .font(.title3.bold())
                Spacer()
            }
            .padding(14)
            Divider()

            Form {
                Section("Paramètres de lancement") {
                    Picker("Modèle (LLM)", selection: $modelId) {
                        let groups = Dictionary(grouping: vm.availableModels, by: { $0.provider })
                        ForEach([LLMModel.Provider.anthropic, .ollama], id: \.self) { provider in
                            if let models = groups[provider], !models.isEmpty {
                                Section(provider.label) {
                                    ForEach(models) { m in
                                        Text(m.name).tag(m.id)
                                    }
                                }
                            }
                        }
                    }
                    LabeledContent("Dossier de travail") {
                        HStack(spacing: 8) {
                            Text(displayPath(workingDirectory))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choisir…", action: chooseFolder)
                                .controlSize(.small)
                        }
                    }
                    Picker("Permissions", selection: $permission) {
                        ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Effort de raisonnement", selection: $effort) {
                        ForEach(EffortLevel.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section("Commande terminal équivalente") {
                    Text(verbatim: commandPreview)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Démarrer") { start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 580, height: 480)
        .onAppear {
            modelId = settings.selectedModelId
            workingDirectory = settings.workingDirectory
            permission = settings.permissionMode
            effort = settings.effortLevel
        }
    }

    private var commandPreview: String {
        let m = model
        var env = ""
        if m?.provider == .ollama {
            env = "ANTHROPIC_BASE_URL=\(settings.routerBaseURL) ANTHROPIC_MODEL=\(m?.modelArg ?? "?") "
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
        vm.newConversation()
        dismiss()
    }
}
