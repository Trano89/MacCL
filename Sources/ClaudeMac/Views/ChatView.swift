import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var vm: ChatViewModel
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var instructions = InstructionsStore.shared
    @FocusState private var composerFocused: Bool
    @State private var showInstructions = false

    private static let fallbackSlashCommands = [
        "compact", "context", "init", "review", "security-review", "usage",
    ]

    var body: some View {
        VStack(spacing: 0) {
            transcript
            reasoningPanel
            Divider()
            composer
        }
    }

    @ViewBuilder private var reasoningPanel: some View {
        if !vm.currentReasoning.isEmpty {
            ReasoningPanel(text: vm.currentReasoning, isLive: vm.isRunning)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .readingColumn()
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if vm.items.isEmpty {
                        EmptyState()
                            .padding(.top, 60)
                    }
                    ForEach(vm.items) { item in
                        MessageRow(item: item)
                            .id(item.id)
                    }
                    if vm.isRunning {
                        VStack(alignment: .leading, spacing: 8) {
                            TypingIndicator()
                            if let hint = vm.waitingHint {
                                Label(hint, systemImage: "hourglass")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .id("typing")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 26)
                .padding(.horizontal, 26)
                .readingColumn()
            }
            .onChange(of: vm.items.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.isRunning) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if !vm.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.attachments) { att in
                            AttachmentChip(attachment: att) { vm.removeAttachment(att.id) }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button(action: pickFiles) {
                    Image(systemName: "paperclip").frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Joindre des fichiers")

                TextField("Écrivez à Claude…", text: $vm.composer, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...10)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .stroke(composerFocused ? Theme.accent.opacity(0.6) : Theme.hairline)
                    )
                    .focused($composerFocused)

                slashMenu

                Group {
                    if vm.isRunning {
                        Button(action: vm.stop) {
                            Image(systemName: "stop.fill").frame(width: 20, height: 20)
                        }
                        .tint(.secondary)
                        .help("Interrompre")
                    } else {
                        Button(action: vm.send) {
                            Image(systemName: "arrow.up").frame(width: 20, height: 20)
                        }
                        .tint(Theme.accent)
                        .disabled(!vm.canSend)
                        .keyboardShortcut(.return, modifiers: [])
                        .help("Envoyer (Retour)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            controlsBar
        }
        .padding(16)
        .readingColumn()
        .dropDestination(for: URL.self) { urls, _ in
            vm.addAttachments(urls: urls)
            return true
        }
        .onAppear { composerFocused = true }
        .sheet(isPresented: $showInstructions) {
            InstructionsView()
        }
    }

    /// Claude Code slash commands, inserted into the composer.
    private var slashMenu: some View {
        Menu {
            let commands = vm.slashCommands.isEmpty ? Self.fallbackSlashCommands : vm.slashCommands
            ForEach(commands, id: \.self) { cmd in
                Button("/" + cmd) {
                    vm.composer = "/" + cmd + " "
                    composerFocused = true
                }
            }
        } label: {
            Image(systemName: "slash.circle")
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34, height: 34)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.hairline))
        .help("Commandes Claude Code")
    }

    // MARK: Inline controls (model, permissions, effort, folder, instructions)

    private var controlsBar: some View {
        HStack(spacing: 8) {
            modelMenu
            permissionMenu
            effortMenu
            folderButton
            instructionsButton
            Spacer(minLength: 0)
        }
    }

    private var modelMenu: some View {
        Menu {
            let groups = Dictionary(grouping: vm.availableModels, by: { $0.provider })
            ForEach([LLMModel.Provider.anthropic, .ollama], id: \.self) { provider in
                if let models = groups[provider], !models.isEmpty {
                    Section(provider.label) {
                        ForEach(models) { model in
                            Button {
                                settings.selectedModelId = model.id
                            } label: {
                                if model.id == settings.selectedModelId {
                                    Label(model.name, systemImage: "checkmark")
                                } else {
                                    Text(model.name)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Button {
                Task { await vm.refreshModels() }
            } label: {
                Label("Rafraîchir les modèles Ollama", systemImage: "arrow.clockwise")
            }
        } label: {
            chip(icon: vm.selectedModel.provider == .ollama ? "desktopcomputer" : "cloud",
                 text: vm.selectedModel.name)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var permissionMenu: some View {
        Menu {
            ForEach(PermissionMode.allCases) { mode in
                Button {
                    settings.permissionMode = mode
                } label: {
                    if mode == settings.permissionMode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            chip(icon: "shield", text: settings.permissionMode.label)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var effortMenu: some View {
        Menu {
            ForEach(EffortLevel.allCases) { level in
                Button {
                    settings.effortLevel = level
                } label: {
                    if level == settings.effortLevel {
                        Label(level.label, systemImage: "checkmark")
                    } else {
                        Text(level.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                EffortIndicator(level: settings.effortLevel, compact: true)
                Text(settings.effortLevel.label)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Effort de raisonnement")
    }

    private var folderButton: some View {
        Button(action: chooseFolder) {
            chip(icon: "folder", text: folderDisplayName)
        }
        .buttonStyle(.plain)
        .help("Dossier de travail : \(settings.workingDirectory)")
    }

    private var instructionsButton: some View {
        Button {
            showInstructions = true
        } label: {
            chip(icon: "text.book.closed",
                 text: instructions.activeCount > 0 ? "Instructions · \(instructions.activeCount)" : "Instructions")
        }
        .buttonStyle(.plain)
        .help("Instructions .md injectées dans le prompt")
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: 190)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().stroke(Theme.hairline))
        .contentShape(Capsule())
    }

    private var folderDisplayName: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if settings.workingDirectory == home { return "~" }
        return URL(fileURLWithPath: settings.workingDirectory).lastPathComponent
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.workingDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            settings.workingDirectory = url.path
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choisir des fichiers à joindre"
        if panel.runModal() == .OK {
            vm.addAttachments(urls: panel.urls)
        }
    }
}

// MARK: - Empty state

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
            Text("Écrivez un message pour commencer")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Typing indicator

private struct TypingIndicator: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 7, height: 7)
                    .opacity(0.35 + 0.65 * abs(sin(phase + Double(i) * 0.6)))
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}
