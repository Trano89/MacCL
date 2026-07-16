import Foundation
import Combine
import AppKit

/// A small utility to generate stable IDs for chat items that need them.
private var _itemCounter: Int64 = 0
private let _itemCounterLock = NSLock()

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var composer: String = ""
    @Published var attachments: [Attachment] = []
    @Published var isRunning = false
    @Published var statusLine: String
    /// Transient "still working" hint shown while waiting — never added to the transcript.
    @Published var waitingHint: String?
    /// The current (latest) turn's reasoning, shown in the panel under the transcript.
    @Published var currentReasoning: String = ""
    @Published var totalCostUSD: Double = 0
    /// Monotonic counter incremented whenever items are modified. Drives transcript scroll.
    @Published var itemsToken = 0
    /// Signal to the transcript that items were mutated (not just appended).
    private func bumpItemsToken() { itemsToken += 1 }
    @Published var availableModels: [LLMModel] = LLMModel.anthropicCatalog
    @Published var claudeAvailable = true
    /// Elapsed seconds since the current turn started (for the agent progress button timer).
    @Published var turnElapsedSeconds: Int = 0
    private var turnStartTime: Date?
    private var elapsedTimerTask: Task<Void, Never>?

    private func startTurnTimer() {
        turnStartTime = Date()
        elapsedTimerTask?.cancel()
        elapsedTimerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                if let start = self.turnStartTime {
                    let elapsed = Int(Date().timeIntervalSince(start))
                    await MainActor.run { self.turnElapsedSeconds = elapsed }
                }
            }
        }
    }

    private func stopTurnTimer() {
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil
        turnElapsedSeconds = 0
        turnStartTime = nil
    }

    /// Slash commands reported by the running claude session (init event).
    @Published var slashCommands: [String] = []
    /// Extra instructions for THIS conversation (appended to the system prompt).
    @Published var conversationInstructions: String = ""
    private var currentGroup: String?

    private let settings: AppSettings
    private var session = ClaudeSession()
    private var toolIndex: [String: Int] = [:]
    private var sessionId: String?
    /// Stable counter for chat item IDs — used as a fallback when no external ID is available.
    private var itemCounter: Int64 = 0
    private func nextItemId() -> String {
        _itemCounterLock.lock(); defer { _itemCounterLock.unlock() }
        itemCounter += 1
        return "item-\(itemCounter)"
    }
    /// Circular buffer for stderr text — rotates every 2 KB to avoid holding sensitive data.
    private var stderrTail: String = ""
    private let maxStderrTail = 1024
    private var sawResultSinceLastTurn = false
    private var watchdog: Task<Void, Never>?
    private var receivedContentThisTurn = false
    private var didInterrupt = false
    /// Sub-agent monitor for the side panel.
    let agentMonitor: AgentMonitorModel = .init()
    /// Pending task results keyed by temporary ID until we can match them to AgentState entries.
    private var pendingTaskResults: [String: String] = [:]
    // Live-streaming state (partial messages): index of the in-progress
    // assistant text item, and whether this message's thinking already streamed.
    /// Pre-allocated stable ID for the current streaming text item, so ForEach .id() stays stable.
    private var _streamingItemId: String?
    private var streamingTextIndex: Int?
    private var streamedThinkingThisMessage = false
    private var lastSentBlocks: [[String: Any]]?
    private var autoCompacting = false
    private var autoCompactTriedThisTurn = false
    var currentConversationId: String?
    private var conversationCreatedAt = Date()
    private var resumeOnNextStart = false
    private var cancellables = Set<AnyCancellable>()
    /// Background scanner for new Ollama servers on the network.
    private var periodicScanner: OllamaDiscovery.PeriodicScanner?
    /// Network reachability monitor — fires when connectivity changes.
    private var reachabilityMonitor: OllamaDiscovery.ReachabilityMonitor?
    /// Detects foreground ↔ background transitions to trigger process healing.
    private let lifecycleObserver = AppLifecycleObserver()
    /// Monitors router/session health and auto-heals on background return.
    private var healthMonitor: AppHealthMonitor!
    /// Epoch of the current session's server URL — used to detect mid-conversation disconnects.
    private var serverEpochURL: String = ""
    /// Opaque token invalidated when the session is replaced.
    /// Stale callbacks check this on every invocation so that events from an old
    /// session (dequeued late via DispatchQueue.main.async) cannot mutate another
    /// conversation's items.
    private var sessionEpoch: UUID = .init()

    /// Token to remove the app-quit notification observer — prevents zombie callbacks.
    private var quitObserver: NSObjectProtocol?

    init(settings: AppSettings) {
        self.settings = settings
        statusLine = L10n.t("ready")
        // Initialize monitors after wire() (which captures `self`) and before start().
        reachabilityMonitor = OllamaDiscovery.ReachabilityMonitor(delegate: self)
        reachabilityMonitor?.startMonitoring()
        periodicScanner = OllamaDiscovery.PeriodicScanner(interval: 30, delegate: self)
        // Start the background scanner immediately.
        periodicScanner?.start(configuredServer: settings.ollamaBaseURL)
        // Wire up lifecycle observer (foreground/background).
        lifecycleObserver.delegate = self
        healthMonitor = AppHealthMonitor(delegate: self)
        // Re-list models when the Ollama server changes (e.g. picked from a scan).
        settings.$ollamaBaseURL
            .dropFirst()
            .debounce(for: .seconds(0.15), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.refreshModels() } }
            .store(in: &cancellables)
        // Terminate the claude child on app quit so it doesn't outlive the app.
        // Store the observer token to remove it when this VM is deallocated or replaced.
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.session.stop() }
        }
    }

    deinit {
        // Clean up the notification observer to prevent zombie callbacks.
        if let token = quitObserver {
            NotificationCenter.default.removeObserver(token)
        }
        reachabilityMonitor?.stopMonitoring()
        periodicScanner?.stop()
    }

    var selectedModel: LLMModel {
        availableModels.first { $0.id == settings.selectedModelId }
            ?? LLMModel.anthropicCatalog.first
                ?? LLMModel(id: "anthropic:opus", provider: .anthropic, name: "Claude Opus 4.8", modelArg: "opus", subtitle: nil)
    }

    var canSend: Bool {
        let hasText = !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachments.isEmpty) && !isRunning
    }

    // MARK: - Actions

    func send() {
        ModelRouter.shared.stopKeepAlive()
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = attachments
        guard (!text.isEmpty || !atts.isEmpty), !isRunning else { return }

        var blocks: [[String: Any]] = []
        if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
        for att in atts { blocks.append(contentsOf: att.contentBlocks()) }

        composer = ""
        attachments = []
        pendingTaskResults.removeAll()
        agentMonitor.clearAll()
        currentReasoning = "" // reset reasoning for the new turn
        streamingTextIndex = nil
        streamedThinkingThisMessage = false
        _streamingItemId = nil
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

    /// Attach an image (or file) from the clipboard. Returns false when the
    /// clipboard holds no image/file, so the caller can let plain text paste
    /// normally into the composer.
    @discardableResult
    func pasteFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        // Copied files (incl. image files) → normal attachment loading.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            addAttachments(urls: urls)
            return true
        }
        // Raw image bytes (screenshots, "Copy Image" from a browser, etc.).
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), let att = Attachment.fromImageData(data) {
                attachments.append(att)
                return true
            }
        }
        if let image = NSImage(pasteboard: pb),
           let tiff = image.tiffRepresentation,
           let att = Attachment.fromImageData(tiff) {
            attachments.append(att)
            return true
        }
        return false
    }

    func stop() {
        watchdog?.cancel()
        waitingHint = nil
        if session.isRunning {
            // Abort the current turn but keep the session alive so the user can
            // immediately send another instruction (or continue).
            didInterrupt = true
            sessionEpoch = .init()    // invalidate pending callbacks from this session
            session.interrupt()
            resumeOnNextStart = true  // fallback: if the process later dies, resume
        } else {
            sessionEpoch = .init()    // invalidate any queued exit callback
            session.stop()
        }
        ModelRouter.shared.stopKeepAlive()
        isRunning = false
        statusLine = L10n.t("interrupted")
        stopTurnTimer()
    }

    func newConversation() {
        watchdog?.cancel()
        waitingHint = nil
        ModelRouter.shared.stopKeepAlive()
        sessionEpoch = .init()    // invalidate any pending callbacks from old session
        session.stop()
        session = ClaudeSession()
        wire()                    // rewire with fresh epoch
        items = []
        bumpItemsToken()
        toolIndex.removeAll()
        sessionId = nil
        currentConversationId = nil
        conversationCreatedAt = Date()
        resumeOnNextStart = false
        totalCostUSD = 0
        currentReasoning = ""
        streamingTextIndex = nil
        streamedThinkingThisMessage = false
        _streamingItemId = nil
        isRunning = false
        statusLine = L10n.t("new_conversation")
        conversationInstructions = ""
        currentGroup = nil
        agentMonitor.clearAll()
        stopTurnTimer()
    }

    /// Load a conversation from history. Continuing it resumes the claude session.
    func load(_ summary: ConversationSummary) {
        guard let convo = ConversationStore.shared.load(summary.id) else { return }
        watchdog?.cancel()
        waitingHint = nil
        ModelRouter.shared.stopKeepAlive()
        session.stop()
        session = ClaudeSession()
        wire()                     // rewire with fresh epoch
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
        _streamingItemId = nil
        isRunning = false
        statusLine = L10n.t("conversation_loaded")
        // Restore the conversation's own parameters so a follow-up runs with the
        // exact same launch configuration (model, cwd, permissions, effort).
        settings.workingDirectory = convo.workingDirectory
        if availableModels.contains(where: { $0.id == convo.modelId }) {
            settings.selectedModelId = convo.modelId
        }
        if let pm = convo.permissionMode { settings.permissionModeRaw = pm }
        if let ef = convo.effort { settings.effortLevelRaw = ef }
        conversationInstructions = convo.instructions ?? ""
        currentGroup = convo.group
    }

    /// Assign a conversation to a group (nil clears it).
    func assignGroup(_ summary: ConversationSummary, group: String?) {
        ConversationStore.shared.setGroup(summary.id, group: group)
        if summary.id == currentConversationId { currentGroup = group }
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
            instructions: conversationInstructions.isEmpty ? nil : conversationInstructions,
            group: currentGroup,
            items: items,
            totalCostUSD: totalCostUSD
        )
        ConversationStore.shared.save(convo)
    }

    /// Library instructions + this conversation's own instructions.
    private func composedSystemPrompt() -> String {
        var parts: [String] = []
        let lib = InstructionsStore.shared.combinedPrompt()
        if !lib.isEmpty { parts.append(lib) }
        let conv = conversationInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !conv.isEmpty { parts.append(conv) }
        return parts.joined(separator: "\n\n---\n\n")
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
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s: first hint
            guard let self, self.isRunning, !self.receivedContentThisTurn else { return }
            self.waitingHint = model.provider == .ollama
                ? L10n.t("waiting_local", model.name)
                : L10n.t("waiting_remote", model.name)
            try? await Task.sleep(nanoseconds: 25_000_000_000) // 25s: "still running"
            guard self.isRunning, !self.receivedContentThisTurn else { return }
            self.waitingHint = L10n.t("still_running")
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
                statusLine = L10n.t("ollama_fallback")
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
            appendNotice(.error, L10n.t("binary_not_found"))
            isRunning = false
            return
        }
        claudeAvailable = true

        let model = selectedModel
        isRunning = true
        sawResultSinceLastTurn = false
        statusLine = L10n.t("sending_to", model.name)
        startWatchdog(for: model)
        startTurnTimer()

        // For local models, make sure the router is up.
        if let err = await ModelRouter.shared.prepare(for: model, settings: settings) {
            appendNotice(.error, err)
            isRunning = false
            statusLine = L10n.t("router_error")
            return
        }

        // Keep the proxy alive even when no turn is active — prevents macOS from
        // pruning the connection while the app is in the background.  This is the key
        // mechanism that keeps remote Ollama bridges operational across alt-tab.
        if model.provider == .ollama || model.provider == .ollamaNetwork {
            // Ping whichever bridge is actually serving this turn.
            ModelRouter.shared.startKeepAlive(
                port: ModelRouter.shared.activeBridgePort(settings: settings),
                healthPath: ModelRouter.shared.activeBridgeHealthPath(settings: settings))
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
            appendSystemPrompt: composedSystemPrompt(),
            streamPartial: settings.streamPartialMessages,
            sessionId: sid,
            extraEnv: extraEnv
        )
        do {
            sessionEpoch = .init()     // fresh epoch for the new session; old callbacks die
            let resumed = resumeOnNextStart
            AppLog.write("session", "start model=\(model.modelArg) provider=\(model.provider.rawValue) "
                         + "bridge=\(settings.bridgeEngine.rawValue) base=\(extraEnv["ANTHROPIC_BASE_URL"] ?? "direct") "
                         + "ctx=\(settings.ollamaNumCtx) effort=\(settings.effortLevel.cliValue) resume=\(resumed)")
            try session.start(config: config, firstContent: blocks, resume: resumed)
            resumeOnNextStart = false
            appendNotice(.info, launchCommandLine(model: model, sessionId: sid, resumed: resumed))
        } catch {
            appendNotice(.error, L10n.t("launch_failed"))
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
        let myEpoch = sessionEpoch   // snapshot at wiring time
        session.onEvent = { [weak self] env in
            guard let strongSelf = self, strongSelf.sessionEpoch == myEpoch else { return }
            strongSelf.handle(env)
        }
        session.onStderr = { [weak self] s in
            guard let strongSelf = self, strongSelf.sessionEpoch == myEpoch else { return }
            strongSelf.handleStderr(s)
        }
        session.onExit = { [weak self] code in
            guard let strongSelf = self, strongSelf.sessionEpoch == myEpoch else { return }
            strongSelf.handleExit(code)
        }
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
                        var copy = items[idx]
                        copy.kind = .assistantText(t)
                        items.replaceSubrange(idx...idx, with: [copy])
                        bumpItemsToken()
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
                    // Track sub-agents for the monitor panel.
                    if name == "Task" {
                        agentMonitor.addAgent(
                            description: input["description"]?.asString ?? "",
                            name: input["name"]?.asString
                        )
                        // Store the toolUseId so we can match the result later.
                        pendingTaskResults[id] = input["description"]?.asString ?? ""
                    }
                    let activity = ToolActivity(toolUseId: id, name: name, input: input)
                    let item = ChatItem(id: "tool-\(id)", kind: .tool(activity))
                    items.append(item)
                    bumpItemsToken()
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
                    // If this is a Task tool result, update the agent monitor.
                    if pendingTaskResults.removeValue(forKey: tid) != nil {
                        let output = isErr ? "" : text
                        agentMonitor.onTaskResult(toolUseId: tid, output: output)
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
                    appendNotice(.info, L10n.t("compacted_resend"))
                    Task { await launchOrContinue(blocks) }
                    return
                }
                appendNotice(.warning, L10n.t("compact_failed"))
            }
            isRunning = false
            let info = ResultInfo(isError: env.isError ?? false, text: env.result,
                                  costUsd: env.totalCostUsd, durationMs: env.durationMs,
                                  numTurns: env.numTurns)
            appendItem(.result(info))
            if let c = env.totalCostUsd { totalCostUSD += c }
            // Settle all active agents when turn ends.
            agentMonitor.settleTurn()
            pendingTaskResults.removeAll()
            statusLine = (env.isError ?? false) ? L10n.t("done_error") : L10n.t("ready")
            persist()
        case "stream_event":
            handleStreamEvent(env.event)
        case "control_request":
            // v0.1 runs in non-interactive permission modes, so nothing should
            // arrive here. If it does, we cannot answer correctly yet — surface it.
            appendNotice(.warning, L10n.t("permission_pending"))
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
                    var copy = items[idx]
                    copy.kind = .assistantText(existing + t)
                    items.replaceSubrange(idx...idx, with: [copy])
                    bumpItemsToken()
                } else {
                    // Allocate a stable ID upfront so ForEach .id() remains stable.
                    let id = _streamingItemId ?? nextItemId()
                    if _streamingItemId == nil { _streamingItemId = id }
                    appendItem(.assistantText(t))
                    streamingTextIndex = items.count - 1
                }
            }
        default:
            break
        }
    }

    private func handleStderr(_ s: String) {
        // Redact potential secrets before storing — avoid leaking API keys / tokens.
        let redacted = secretRedactor.redact(s)
        stderrTail = String((stderrTail + redacted).suffix(maxStderrTail))
        AppLog.write("claude", redacted)
    }

    /// Match actual Claude Code v2.x context-limit error messages.
    private static let contextLimitPatterns = [
        "exceeds the available context size",
        "exceed_context_size",
        "prompt is too long",
        "context_length",
        "context window",
        "context low",
        "max context length",
        "context size exceeded",
        "reaching the context limit",
        "prompt exceeds the maximum length",
    ]

    /// True when a turn died because the context window is full.
    private func shouldAutoCompact(_ env: StreamEnvelope) -> Bool {
        guard !autoCompactTriedThisTurn, env.isError == true,
              let text = env.result?.lowercased() else { return false }
        return Self.contextLimitPatterns.contains { text.contains($0) }
    }

    /// Run `/compact` in the live session; the next result re-sends the message.
    private func startAutoCompact() {
        autoCompactTriedThisTurn = true
        autoCompacting = true
        isRunning = true
        statusLine = L10n.t("compacting")
        appendNotice(.info, L10n.t("compact_notice"))
        session.send(content: [["type": "text", "text": "/compact"]])
    }

    private func handleExit(_ code: Int32) {
        watchdog?.cancel()
        waitingHint = nil
        autoCompacting = false
        let wasRunning = isRunning
        isRunning = false
        AppLog.write("claude", "session exited: code=\(code) sawResult=\(sawResultSinceLastTurn) wasRunning=\(wasRunning)")
        // A turn that ends without a result produced nothing. Surface it even when
        // the exit code is 0 — a silent exit used to leave the UI blank after
        // minutes of work ("it ran two minutes then nothing"). Skip only when the
        // user interrupted on purpose.
        if wasRunning && !sawResultSinceLastTurn && !didInterrupt {
            let hint = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            var message = L10n.t("session_terminated", String(code))
            if !hint.isEmpty { message += "\n\n" + hint }
            appendNotice(.error, message)
            statusLine = L10n.t("session_stopped")
        }
        didInterrupt = false
        persist()
    }

    // MARK: - Item helpers

    private func appendItem(_ kind: ChatItem.Kind) {
        items.append(ChatItem(id: nextItemId(), kind: kind))
        bumpItemsToken()
    }

    private func appendNotice(_ level: Notice.Level, _ text: String) {
        appendItem(.notice(Notice(level: level, text: text)))
    }

    private func updateTool(_ id: String, _ mutate: (inout ToolActivity) -> Void) {
        guard let idx = toolIndex[id], idx < items.count,
              case .tool(var act) = items[idx].kind else { return }
        mutate(&act)
        var copy = items[idx]
        copy.kind = .tool(act)
        items.replaceSubrange(idx...idx, with: [copy])
        bumpItemsToken()
    }
}

// MARK: - Server discovery & reachability delegate conformances

extension ChatViewModel: OllamaDiscovery.ServerDiscoveryDelegate {
    @MainActor
    func didDiscoverServer(_ server: OllamaDiscovery.Server) {
        // Add to standby servers if not already present.
        if !settings.standbyServers.contains(where: { $0.url == server.url }) {
            settings.addStandbyServer(server.standbyServer)
        }
        // If the currently selected URL is unreachable, try auto-switching to this one.
        Task { [weak self] in await self?.tryAutoSwitchTo(server) }
    }

    /// Check if `server` works and auto-switch if the current server is dead.
    private func tryAutoSwitchTo(_ server: OllamaDiscovery.Server) async {
        let serverReachable = await OllamaClient.isReachable(baseURL: settings.ollamaBaseURL)
        guard !serverReachable else { return }
        guard let url = URL(string: server.url), let host = url.host, !host.isEmpty else { return }
        let localHosts: Set<String> = ["localhost", "127.0.0.1"]
        guard localHosts.contains(host) || server.url.hasPrefix("http://") else { return }
        if await OllamaClient.isReachable(baseURL: server.url) {
            settings.ollamaBaseURL = server.url
            await refreshModels()
            let wasLocalOnly = (settings.ollamaBaseURL == "http://localhost:11434")
            if localHosts.contains(host) && !wasLocalOnly {
                statusLine = L10n.t("ollama_fallback")
            }
        }
    }
}

extension ChatViewModel: OllamaDiscovery.ReachabilityDelegate {
    @MainActor
    func didChangeNetworkReachable(_ reachable: Bool) {
        if reachable {
            // Network back — trigger immediate scan and model refresh.
            Task { await self.periodicScanner?.runScan(configuredServer: settings.ollamaBaseURL) }
            Task { await self.refreshModels() }
        }
    }
}

// MARK: - App lifecycle (background/foreground) — auto-heal on return

extension ChatViewModel: AppLifecycleDelegate {
    func appDidEnterBackground() {
        // No action needed — the process just gets suspended.
        // healthMonitor will detect it dead on return.
    }

    func appDidBecomeActive() {
        // The router almost certainly died while backgrounded.
        // Heal immediately: stop dead process, restart router, re-validate session.
        Task { await self.healAfterBackgrounding() }
    }
}

// MARK: - Health monitor delegate conformance

extension ChatViewModel: HealthDelegate {
    func willRestartRouter() {
        statusLine = L10n.t("router_restarting")
    }

    /// A turn is in flight — the health monitor must not restart the bridge now.
    var isTurnInFlight: Bool { isRunning }

    func routerDidRestart() {
        // If a session is running, check it's still healthy; if not, signal to the user.
        Task {
            let isHealthy = await ModelRouter.shared.bridgeHealthy(settings: settings)
            await MainActor.run {
                if isHealthy {
                    statusLine = L10n.t("router_recovered")
                } else {
                    statusLine = L10n.t("router_recovery_failed")
                    Task { await self.tryAutoSwitchTo(OllamaDiscovery.Server(url: "http://localhost:11434", host: "localhost", modelCount: 0)) }
                }
            }
        }
    }

    func healFailed(error: String) {
        statusLine = L10n.t("heal_failed")
    }
}

// MARK: - Auto-heal after backgrounding

extension ChatViewModel {
    /// Full healing flow: verify router is alive, restart it if not, and re-attach
    /// the session if the claude process died while backgrounded.
    @MainActor
    private func healAfterBackgrounding() async {
        // Never heal mid-turn: restarting the bridge kills the in-flight request
        // and leaves `claude` hanging forever.
        guard !isRunning else { return }
        guard let currentModel = (sessionId != nil || !items.isEmpty) ? selectedModel : nil else {
            return  // No active session to recover
        }

        let wasOllama = currentModel.provider == .ollama || currentModel.provider == .ollamaNetwork

        // Step 1: Is the bridge still alive? (Probe its own health endpoint — the
        // bridge doesn't serve Ollama's /api/tags.) If not, restart it.
        let routerAlive = await ModelRouter.shared.bridgeHealthy(settings: settings)
        if wasOllama && !routerAlive {
            AppLog.write("health", "bridge unreachable after foreground — restarting")
            statusLine = L10n.t("router_restarting")

            // Stop dead router, then re-prepare with same model.
            ModelRouter.shared.shutdown()

            let prepareErr = await ModelRouter.shared.prepare(for: currentModel, settings: settings)
            if let err = prepareErr {
                appendNotice(.error, L10n.t("router_error"))
                statusLine = err
                return
            }

            statusLine = L10n.t("router_recovered")
        }

        // Step 2: If claude session died (process terminated), the next user message
        // will auto-restart via ClaudeSession.send() → spawn with --resume.
        // We just need to ensure the user sees a hint that things are back.
        if !wasOllama {
            // For Anthropic models, no local router is involved — nothing to heal.
            // Just verify connectivity.
            statusLine = L10n.t("ready")
        }

        // Step 3: Refresh models list (servers may have changed while backgrounded).
        await refreshModels()
    }
}

// MARK: - Mid-conversation server health check

extension ChatViewModel {
    /// Check if the current Ollama server is still reachable; auto-fallback to localhost if not.
    private func checkServerHealth() async -> Bool {
        let isOllamaModel = selectedModel.provider == .ollama || selectedModel.provider == .ollamaNetwork
        guard isOllamaModel else { return true }

        // If URL changed since session started, update epoch and re-check.
        if serverEpochURL != settings.ollamaBaseURL {
            serverEpochURL = settings.ollamaBaseURL
            return await OllamaClient.isReachable(baseURL: settings.ollamaBaseURL)
        }

        // Current server alive? Nothing to do.
        if await OllamaClient.isReachable(baseURL: settings.ollamaBaseURL) {
            return true
        }

        // Current server gone — try localhost as fallback.
        if await OllamaClient.isReachable(baseURL: "http://localhost:11434") {
            settings.ollamaBaseURL = "http://localhost:11434"
            statusLine = L10n.t("ollama_fallback")
            return true
        }

        // No Ollama available — nothing we can do.
        return false
    }
}

// MARK: - Secret redactor (simple pattern-based sanitization for stderr logs)

private enum secretRedactor {
    // Regexes compiled once; re-used on every call to avoid per-call allocation/compilation.
    private static let compiled = { () -> [NSRegularExpression] in
        var result: [NSRegularExpression] = []
        for pat in [
            "sk-[A-Za-z0-9]{20,}",
            "ghp_[A-Za-z0-9]{36}",
            "glpat-[A-Za-z0-9]{20,}",
            "[A-Za-z0-9+/]{40,}={0,2}",
        ] {
            if let rx = try? NSRegularExpression(pattern: pat) { result.append(rx) }
        }
        return result
    }()

    static func redact(_ text: String) -> String {
        var result = text
        for regex in compiled {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: "[REDACTED]"
            )
        }
        // Mask URLs that look like they contain API keys (e.g. ?key=...)
        result = result.replacingOccurrences(
            of: #"(https?://[^&\s]+)\?[^=]*=([^&\s]+)"#,
            with: "$1?[REDACTED]",
            options: .regularExpression
        )
        return result
    }
}
