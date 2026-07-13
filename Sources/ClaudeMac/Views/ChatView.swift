import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var vm: ChatViewModel
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var instructions = InstructionsStore.shared
    @FocusState private var composerFocused: Bool
    @State private var showInstructions = false
    @State private var showSlashCommands = false
    @State private var showModelPicker = false

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
            // Drop zone for attachments. Kept OFF the composer: a drop handler
            // there swallows the mouse-down that opens the inline menus.
            .dropDestination(for: URL.self) { urls, _ in
                vm.addAttachments(urls: urls)
                return true
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
        .onAppear { composerFocused = true }
        .sheet(isPresented: $showInstructions) {
            InstructionsView()
        }
    }

    /// Claude Code slash commands, inserted into the composer.
    private var slashMenu: some View {
        Button {
            showSlashCommands = true
        } label: {
            Image(systemName: "slash.circle").frame(width: 20, height: 20)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .help("Commandes Claude Code")
        .sheet(isPresented: $showSlashCommands) {
            SlashCommandsSheet(
                commands: vm.slashCommands.isEmpty ? Self.fallbackSlashCommands : vm.slashCommands
            ) { cmd in
                vm.composer = "/" + cmd + " "
                composerFocused = true
            }
        }
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
        Button {
            showModelPicker = true
        } label: {
            Label(vm.selectedModel.name,
                  systemImage: vm.selectedModel.provider == .ollama ? "desktopcomputer" : "cloud")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Choisir le modèle (LLM)")
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(vm: vm)
        }
    }

    /// Click cycles to the next permission mode (tooltip explains the current one).
    private var permissionMenu: some View {
        Button {
            let all = PermissionMode.allCases
            let idx = all.firstIndex(of: settings.permissionMode) ?? 0
            settings.permissionMode = all[(idx + 1) % all.count]
        } label: {
            Label(settings.permissionMode.label, systemImage: "shield")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Permissions — cliquer pour changer. \(settings.permissionMode.explanation)")
    }

    /// Click cycles the reasoning effort level.
    private var effortMenu: some View {
        Button {
            let all = EffortLevel.allCases
            let idx = all.firstIndex(of: settings.effortLevel) ?? 0
            settings.effortLevel = all[(idx + 1) % all.count]
        } label: {
            HStack(spacing: 4) {
                EffortIndicator(level: settings.effortLevel, compact: true)
                Text(settings.effortLevel.label)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Effort de raisonnement — cliquer pour changer. \(settings.effortLevel.explanation)")
    }

    private var folderButton: some View {
        Button(action: chooseFolder) {
            Label(folderDisplayName, systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Dossier de travail : \(settings.workingDirectory)")
    }

    private var instructionsButton: some View {
        Button {
            showInstructions = true
        } label: {
            Label(instructions.activeCount > 0 ? "Instructions · \(instructions.activeCount)" : "Instructions",
                  systemImage: "text.book.closed")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Instructions .md injectées dans le prompt")
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
