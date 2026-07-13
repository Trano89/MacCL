import Foundation
import Combine
import AppKit

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var composer: String = ""
    @Published var attachments: [Attachment] = []
    @Published var isRunning = false
    @Published var statusLine = "Prêt"
    /// Transient "still working" hint shown while waiting — never added to the transcript.
    @Published var waitingHint: String?
    /// The current (latest) turn's reasoning, shown in the panel under the transcript.
    @Published var currentReasoning: String = ""
    @Published var totalCostUSD: Double = 0
    @Published var availableModels: [LLMModel] = LLMModel.anthropicCatalog
    @Published var claudeAvailable = true
    /// Slash commands reported by the running claude session (init event).
    @Published var slashCommands: [String] = []

    private let settings: AppSettings
    private var session = ClaudeSession()
    private var toolIndex: [String: Int] = [:]
    private var sessionId: String?
    private var itemCounter = 0
    private var stderrTail = ""
    private var sawResultSinceLastTurn = false
    private var watchdog: Task<Void, Never>?
    private var receivedContentThisTurn = false
    private var didInterrupt = false
    // Live-streaming state (partial messages): index of the in-progress
    // assistant text item, and whether this message's thinking already streamed.
    private var streamingTextIndex: Int?
    private var streamedThinkingThisMessage = false
    // Auto-compaction: when a turn dies on a context-size limit, run /compact
    // then re-send the last user message automatically.
    private var lastSentBlocks: [[String: Any]]?
    private var autoCompacting = false
    private var autoCompactTriedThisTurn = false
    private var currentConversationId: String?
    private var conversationCreatedAt = Date()
    private var resumeOnNextStart = false
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        wire()
        Task { await refreshModels() }
        // Re-list models when the Ollama server changes (e.g. picked from a scan).
        settings.$ollamaBaseURL
            .dropFirst()
            .debounce(for: .seconds(0.4), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.refreshModels() } }
            .store(in: &cancellables)
        // Terminate the claude child on app quit so it doesn't outlive the app.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.stop() }
        }
    }

    var selectedModel: LLMModel {
        availableModels.first { $0.id == settings.selectedModelId }
            ?? LLMModel.anthropicCatalog.first!
    }

    var canSend: Bool {
        let hasText = !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachments.isEmpty) && !isRunning
    }

    // MARK: - Actions

    func send() {
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = attachments
        guard (!text.isEmpty || !atts.isEmpty), !isRunning else { return }

        var blocks: [[String: Any]] = []
        if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
        for att in atts { blocks.append(contentsOf: att.contentBlocks()) }

        composer = ""
        attachments = []
        currentReasoning = "" // reset reasoning for the new turn
        streamingTextIndex = nil
        streamedThinkingThisMessage = false
        lastSentBlocks = blocks
        autoCompactTriedThisTurn = false
        if currentConversationId == nil {
            let newId = UUID().uuidString
            currentConversationId = newId
            sessionId = newId
            conversationCreatedAt = Date()
        }
        appendItem(.user(text: text, attachments: atts))
        persist()
        Task { await launchOrContinue(blocks) }
    }

    func addAttachments(urls: [URL]) {
        Task.detached {
            let loaded = urls.compactMap { Attachment.load(from: $0) }
            guard !loaded.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.attachments.append(contentsOf: loaded)
            }
        }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func stop() {
        watchdog?.cancel()
        waitingHint = nil
        if session.isRunning {
            // Abort the current turn but keep the session alive so the user can
            // immediately send another instruction (or continue).
            didInterrupt = true
            session.interrupt()
            resumeOnNextStart = true // fallback: if the process later dies, resume
        } else {
            session.stop()
        }
        isRunning = false
        statusLine = "Interrompu"
    }

    func newConversation() {
        watchdog?.cancel()
        waitingHint = nil
        session.stop()
        session = ClaudeSession()
        wire()
        items.removeAll()
        toolIndex.removeAll()
        sessionId = nil
        currentConversationId = nil
        conversationCreatedAt = Date()
        resumeOnNextStart = false
        totalCostUSD = 0
        currentReasoning = ""
        streamingTextIndex = nil
        streamedThinkingThisMessage = false
        isRunning = false
        statusLine = "Nouvelle conversation"
    }

    /// Load a conversation from history. Continuing it resumes the claude session.
    func load(_ summary: ConversationSummary) {
        guard let convo = ConversationStore.shared.load(summary.id) else { return }
        watchdog?.cancel()
        waitingHint = nil
        session.stop()
        session = ClaudeSession()
        wire()
        items = convo.items
        rebuildToolIndex()
        currentConversationId = convo.id
        sessionId = convo.id
        conversationCreatedAt = convo.createdAt
        totalCostUSD = convo.totalCostUSD
        resumeOnNextStart = true // next message continues the persisted session
        currentReasoning = ""
        streamingTextIndex = nil
        streamedThinkingThisMessage = false
        isRunning = false
        statusLine = "Conversation chargée"
        // Restore the conversation's own parameters so a follow-up runs with the
        // exact same launch configuration (model, cwd, permissions, effort).
        settings.workingDirectory = convo.workingDirectory
        if availableModels.contains(where: { $0.id == convo.modelId }) {
            settings.selectedModelId = convo.modelId
        }
        if let pm = convo.permissionMode { settings.permissionModeRaw = pm }
        if let ef = convo.effort { settings.effortLevelRaw = ef }
    }

    func deleteConversation(_ summary: ConversationSummary) {
        ConversationStore.shared.delete(summary.id)
        if summary.id == currentConversationId { newConversation() }
    }

    // MARK: - Persistence

    private func persist() {
        guard let id = currentConversationId, !items.isEmpty else { return }
        let convo = Conversation(
            id: id,
            title: conversationTitle(),
            createdAt: conversationCreatedAt,
            updatedAt: Date(),
            modelId: settings.selectedModelId,
            workingDirectory: settings.workingDirectory,
            permissionMode: settings.permissionModeRaw,
            effort: settings.effortLevelRaw,
            items: items,
            totalCostUSD: totalCostUSD
        )
        ConversationStore.shared.save(convo)
    }

    private func conversationTitle() -> String {
        for item in items {
            if case .user(let text, _) = item.kind,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return String(text.prefix(60))
            }
        }
        return "Conversation"
    }

    private func rebuildToolIndex() {
        toolIndex.removeAll()
        for (i, item) in items.enumerated() {
            if case .tool(let act) = item.kind { toolIndex[act.toolUseId] = i }
        }
    }

    /// Surface progress while we wait: a slow local model that is silently
    /// cold-loading should never look like a frozen app.
    private func startWatchdog(for model: LLMModel) {
        watchdog?.cancel()
        receivedContentThisTurn = false
        waitingHint = nil
        // A transient hint (not a transcript notice) — it disappears the moment
        // any content arrives, so it never lingers as a false "no response".
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.isRunning, !self.receivedContentThisTurn else { return }
            self.waitingHint = model.provider == .ollama
                ? "\(model.name) réfléchit… les modèles locaux peuvent être lents au premier tour."
                : "En attente de \(model.name)…"
            try? await Task.sleep(nanoseconds: 70_000_000_000)
            guard self.isRunning, !self.receivedContentThisTurn else { return }
            self.waitingHint = "Toujours en cours (gros modèle ou long prompt) — vous pouvez patienter ou cliquer sur ⏹."
        }
    }

    func refreshModels() async {
        var models = LLMModel.anthropicCatalog
        var ollama = await OllamaClient.listModels(baseURL: settings.ollamaBaseURL)
        // Failover: if the configured server is unreachable but a local Ollama
        // runs, switch to it rather than silently listing no local models.
        if ollama.isEmpty, settings.ollamaBaseURL != "http://localhost:11434" {
            let local = await OllamaClient.listModels(baseURL: "http://localhost:11434")
            if !local.isEmpty {
                settings.ollamaBaseURL = "http://localhost:11434"
                ollama = local
                statusLine = "Serveur Ollama injoignable — bascule sur localhost"
            }
        }
        models += ollama
        availableModels = models
        // Keep selection valid.
        if !models.contains(where: { $0.id == settings.selectedModelId }) {
            settings.selectedModelId = models.first?.id ?? "anthropic:opus"
        }
    }

    // MARK: - Launch

    private func launchOrContinue(_ blocks: [[String: Any]]) async {
        guard let claudePath = BinaryLocator.find("claude", override: settings.claudePathOverride) else {
            claudeAvailable = false
            appendNotice(.error, "Binaire `claude` introuvable. Renseignez son chemin dans les Réglages (⌘,).")
            isRunning = false
            return
        }
        claudeAvailable = true

        let model = selectedModel
        isRunning = true
        sawResultSinceLastTurn = false
        statusLine = "Envoi à \(model.name)…"
        startWatchdog(for: model)

        // For local models, make sure the router is up.
        if let err = await ModelRouter.shared.prepare(for: model, settings: settings) {
            appendNotice(.error, err)
            isRunning = false
            statusLine = "Erreur routeur"
            return
        }
        let extraEnv = ModelRouter.shared.environment(for: model, settings: settings)

        if session.isRunning {
            session.send(content: blocks)
            return
        }

        let sid = sessionId ?? UUID().uuidString
        sessionId = sid
        let config = SessionConfig(
            claudePath: claudePath,
            workingDirectory: settings.workingDirectory,
            model: model,
            permissionMode: settings.permissionMode,
            effort: settings.effortLevel,
            appendSystemPrompt: InstructionsStore.shared.combinedPrompt(),
            streamPartial: settings.streamPartialMessages,
            sessionId: sid,
            extraEnv: extraEnv
        )
        do {
            let resumed = resumeOnNextStart
            try session.start(config: config, firstContent: blocks, resume: resumed)
            resumeOnNextStart = false
            appendNotice(.info, launchCommandLine(model: model, sessionId: sid, resumed: resumed))
        } catch {
            appendNotice(.error, "Lancement échoué : \(error.localizedDescription)")
            isRunning = false
        }
    }

    /// The literal terminal command this session runs — shown in the transcript
    /// so what the app does is exactly what you'd type in a shell.
    private func launchCommandLine(model: LLMModel, sessionId: String, resumed: Bool) -> String {
        var env = ""
        if model.provider == .ollama {
            env = "ANTHROPIC_BASE_URL=\(settings.routerBaseURL) ANTHROPIC_MODEL=\(model.modelArg) "
        }
        var cmd = "claude -p --input-format stream-json --output-format stream-json --verbose"
        cmd += " --model \(model.modelArg)"
        cmd += " --permission-mode \(settings.permissionMode.cliValue)"
        cmd += " --effort \(settings.effortLevel.cliValue)"
        if settings.streamPartialMessages { cmd += " --include-partial-messages" }
        if !InstructionsStore.shared.combinedPrompt().isEmpty {
            cmd += " --append-system-prompt \"$(cat instructions/*.md)\""
        }
        cmd += resumed ? " --resume \(sessionId)" : " --session-id \(sessionId)"
        return "$ cd \"\(settings.workingDirectory)\"\n$ \(env)\(cmd)"
    }

    // MARK: - Event handling

    private func wire() {
        session.onEvent = { [weak self] env in self?.handle(env) }
        session.onStderr = { [weak self] s in self?.handleStderr(s) }
        session.onExit = { [weak self] code in self?.handleExit(code) }
    }

    private func handle(_ env: StreamEnvelope) {
        if ["assistant", "user", "result", "stream_event"].contains(env.type) {
            receivedContentThisTurn = true
            waitingHint = nil
        }
        switch env.type {
        case "system":
            if env.subtype == "init" {
                sessionId = env.sessionId ?? sessionId
                let model = env.model ?? selectedModel.name
                statusLine = "Session · \(model)"
                if let cmds = env.slashCommands, !cmds.isEmpty {
                    slashCommands = cmds.sorted()
                }
            }
        case "assistant":
            for block in env.message?.content ?? [] {
                switch block {
                case .text(let t) where !t.isEmpty:
                    // If this text streamed live, replace the in-progress item
                    // with the canonical version instead of duplicating it.
                    if let idx = streamingTextIndex, idx < items.count {
                        items[idx].kind = .assistantText(t)
                        streamingTextIndex = nil
                    } else {
                        appendItem(.assistantText(t))
                    }
                case .thinking(let t) where !t.isEmpty:
                    if streamedThinkingThisMessage {
                        streamedThinkingThisMessage = false // already shown live
                    } else {
                        currentReasoning += currentReasoning.isEmpty ? t : "\n\n" + t
                    }
                case .toolUse(let id, let name, let input):
                    let activity = ToolActivity(toolUseId: id, name: name, input: input)
                    let item = ChatItem(id: "tool-\(id)", kind: .tool(activity))
                    items.append(item)
                    toolIndex[id] = items.count - 1
                default:
                    break
                }
            }
            streamingTextIndex = nil
            streamedThinkingThisMessage = false
        case "user":
            for block in env.message?.content ?? [] {
                if case .toolResult(let tid, let text, let isErr) = block {
                    updateTool(tid) { act in
                        act.resultText = text
                        act.isError = isErr
                        act.isRunning = false
                    }
                }
            }
        case "result":
            sawResultSinceLastTurn = true
            watchdog?.cancel()
            // The aborted turn reports its own (error) result — swallow it so it
            // doesn't show as a failure, and don't disturb a turn that may have
            // already been restarted by the user.
            if didInterrupt {
                didInterrupt = false
                return
            }
            // Context limit reached → compact the conversation then retry, instead
            // of failing the turn.
            if shouldAutoCompact(env) {
                startAutoCompact()
                return
            }
            if autoCompacting {
                autoCompacting = false
                if !(env.isError ?? false), let blocks = lastSentBlocks {
                    appendNotice(.info, "Contexte compacté ✓ — renvoi du dernier message…")
                    Task { await launchOrContinue(blocks) }
                    return
                }
                appendNotice(.warning, "Le compactage a échoué — réessayez ou démarrez une nouvelle conversation.")
            }
            isRunning = false
            let info = ResultInfo(isError: env.isError ?? false, text: env.result,
                                  costUsd: env.totalCostUsd, durationMs: env.durationMs,
                                  numTurns: env.numTurns)
            appendItem(.result(info))
            if let c = env.totalCostUsd { totalCostUSD += c }
            statusLine = (env.isError ?? false) ? "Terminé avec erreur" : "Prêt"
            persist()
        case "stream_event":
            handleStreamEvent(env.event)
        case "control_request":
            // v0.1 runs in non-interactive permission modes, so nothing should
            // arrive here. If it does, we cannot answer correctly yet — surface it.
            appendNotice(.warning, "Requête de permission reçue (dialogue natif à venir).")
        default:
            break
        }
    }

    /// Live token streaming: apply thinking/text deltas as they arrive so long
    /// turns (local models with reasoning) never look frozen.
    private func handleStreamEvent(_ event: JSONValue?) {
        guard let event, event["type"]?.asString == "content_block_delta",
              let delta = event["delta"] else { return }
        switch delta["type"]?.asString {
        case "thinking_delta":
            if let t = delta["thinking"]?.asString, !t.isEmpty {
                currentReasoning += t
                streamedThinkingThisMessage = true
            }
        case "text_delta":
            if let t = delta["text"]?.asString, !t.isEmpty {
                if let idx = streamingTextIndex, idx < items.count,
                   case .assistantText(let existing) = items[idx].kind {
                    items[idx].kind = .assistantText(existing + t)
                } else {
                    appendItem(.assistantText(t))
                    streamingTextIndex = items.count - 1
                }
            }
        default:
            break
        }
    }

    private func handleStderr(_ s: String) {
        stderrTail = String((stderrTail + s).suffix(2000))
    }

    /// True when a turn died because the context window is full.
    private func shouldAutoCompact(_ env: StreamEnvelope) -> Bool {
        guard !autoCompactTriedThisTurn, env.isError == true,
              let text = env.result?.lowercased() else { return false }
        return text.contains("exceeds the available context size")
            || text.contains("exceed_context_size")
            || text.contains("prompt is too long")
            || text.contains("context_length")
            || text.contains("context window")
            || text.contains("context low")
    }

    /// Run `/compact` in the live session; the next result re-sends the message.
    private func startAutoCompact() {
        autoCompactTriedThisTurn = true
        autoCompacting = true
        isRunning = true
        statusLine = "Contexte plein — compactage…"
        appendNotice(.info, "Limite de contexte atteinte — compactage automatique de la conversation (/compact), puis renvoi du message.")
        session.send(content: [["type": "text", "text": "/compact"]])
    }

    private func handleExit(_ code: Int32) {
        watchdog?.cancel()
        waitingHint = nil
        autoCompacting = false
        isRunning = false
        if code != 0 && !sawResultSinceLastTurn {
            let hint = stderrTail.isEmpty ? "" : "\n\n\(stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))"
            appendNotice(.error, "La session `claude` s'est arrêtée (code \(code)).\(hint)")
            statusLine = "Session arrêtée"
        }
        persist()
    }

    // MARK: - Item helpers

    private func appendItem(_ kind: ChatItem.Kind) {
        itemCounter += 1
        items.append(ChatItem(id: "item-\(itemCounter)", kind: kind))
    }

    private func appendNotice(_ level: Notice.Level, _ text: String) {
        appendItem(.notice(Notice(level: level, text: text)))
    }

    private func updateTool(_ id: String, _ mutate: (inout ToolActivity) -> Void) {
        guard let idx = toolIndex[id], idx < items.count,
              case .tool(var act) = items[idx].kind else { return }
        mutate(&act)
        items[idx].kind = .tool(act)
    }
}
