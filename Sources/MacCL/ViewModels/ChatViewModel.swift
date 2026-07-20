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
    /// Opaque token invalidated when the session is replaced.
    /// Stale callbacks check this on every invocation so that events from an old
    /// session (dequeued late via DispatchQueue.main.async) cannot mutate another
    /// conversation's items.
    private var sessionEpoch: UUID = .init()
    /// Captured epoch for callbacks that fire outside the wire() closure chain
    /// (health monitor delegate calls) — prevents stale callbacks from mutating
    /// a newer conversation's state.
    private var bridgeDeathEpoch: UUID? = nil
    /// Prevents double-tap send: the same UUID guards one in-flight launch task.
    private var activeLaunchTask: UUID? = nil

    /// Token to remove the app-quit notification observer — prevents zombie callbacks.
    private var quitObserver: NSObjectProtocol?

    /// The Ollama server THIS conversation is bound to. Chosen when the
    /// conversation is created, persisted with it, changeable mid-conversation.
    /// Never rewritten behind the user's back.
    @Published var conversationServerURL: String
    /// True while the conversation's server doesn't answer: sending is blocked
    /// (with a visible banner) until the server comes back — no localhost fallback.
    @Published var serverUnavailable = false
    /// Re-probes the bound server while it's unavailable, to unblock automatically.
    private var serverWatchTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        // Seed new conversations with the last server used (pure default — the
        // new-conversation sheet asks explicitly every time).
        conversationServerURL = settings.ollamaBaseURL
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
        // NOTE: the app used to observe a global server setting and re-list
        // models on change; the server now belongs to each conversation, so
        // changes only ever go through changeServer(to:).
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
        if let m = availableModels.first(where: { $0.id == settings.selectedModelId }) { return m }
        // An Ollama model whose server is momentarily down isn't in the list —
        // keep showing IT (the conversation waits for its server; it must not
        // silently morph into an Anthropic one).
        if settings.selectedModelId.hasPrefix("ollama:") {
            let name = String(settings.selectedModelId.dropFirst("ollama:".count))
            return LLMModel.ollama(name, host: serverHost)
        }
        return LLMModel.anthropicCatalog.first
            ?? LLMModel(id: "anthropic:opus", provider: .anthropic, name: "Claude Opus 4.8", modelArg: "opus", subtitle: nil)
    }

    var canSend: Bool {
        let hasText = !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachments.isEmpty) && !isRunning && !isBlockedByServer
    }

    /// A conversation whose server is down cannot continue — until it's back.
    var isBlockedByServer: Bool { usesBridge && serverUnavailable }

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
        let taskId = UUID()
        activeLaunchTask = taskId
        Task { await launchOrContinue(blocks, taskId: taskId) }
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
        // Reset per-turn flags that persist across conversations.
        didInterrupt = false
        sawResultSinceLastTurn = false
        lastSentBlocks = nil
        autoCompacting = false
        activeLaunchTask = nil
        // The new-conversation sheet sets the server right after this call;
        // until then, clear any stale block from the previous conversation.
        serverUnavailable = false
        serverWatchTask?.cancel()
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
        // exact same launch configuration (server, model, cwd, permissions, effort).
        settings.workingDirectory = convo.workingDirectory
        // Its bound server first (older files: fall back to the last-used one) —
        // the model list depends on it.
        conversationServerURL = convo.serverURL ?? settings.ollamaBaseURL
        serverUnavailable = false
        serverWatchTask?.cancel()
        conversationInstructions = convo.instructions ?? ""
        currentGroup = convo.group
        if let pm = convo.permissionMode { settings.permissionModeRaw = pm }
        if let ef = convo.effort { settings.effortLevelRaw = ef }
        // Restore the conversation's model FIRST; refreshModels() then keeps it
        // even when its server is down (the conversation just waits).
        settings.selectedModelId = convo.modelId
        Task { [weak self] in
            guard let self else { return }
            await self.refreshModels()
            // Is the bound server up? If not, the conversation waits for it.
            await self.probeConversationServer()
        }
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
            serverURL: conversationServerURL,
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
        // Models come from the CONVERSATION's server, and from it only. If it
        // doesn't answer, the list is simply empty — never a silent switch to
        // another machine.
        let ollama = await OllamaClient.listModels(baseURL: conversationServerURL)
        let models = LLMModel.anthropicCatalog + ollama
        availableModels = models
        // Keep selection valid — but never discard an Ollama selection just
        // because its server is momentarily down: the conversation is blocked
        // meanwhile and the model comes back with the server.
        if !models.contains(where: { $0.id == settings.selectedModelId }) {
            let waitingForServer = settings.selectedModelId.hasPrefix("ollama:") && ollama.isEmpty
            if !waitingForServer {
                settings.selectedModelId = models.first?.id ?? "anthropic:opus"
            }
        }
    }

    // MARK: - Launch

    private func launchOrContinue(_ blocks: [[String: Any]], taskId: UUID) async {
        // Dedup guard: if a newer send() has superseded this task, drop it.
        guard activeLaunchTask == taskId else { return }
        defer { activeLaunchTask = nil }

        guard let claudePath = BinaryLocator.find("claude", override: settings.claudePathOverride) else {
            claudeAvailable = false
            appendNotice(.error, L10n.t("binary_not_found"))
            isRunning = false
            return
        }
        claudeAvailable = true

        let model = selectedModel

        // The conversation is bound to its server: check it answers BEFORE
        // spending a turn. If it's down, block visibly and watch for its return.
        if model.provider != .anthropic {
            guard await OllamaClient.isReachable(baseURL: conversationServerURL) else {
                serverUnavailable = true
                startServerWatch()
                appendNotice(.error, L10n.t("server_unreachable_blocked", serverHost))
                statusLine = L10n.t("server_waiting", serverHost)
                isRunning = false
                return
            }
            serverUnavailable = false
        }

        isRunning = true
        sawResultSinceLastTurn = false
        statusLine = L10n.t("sending_to", model.name)
        startWatchdog(for: model)
        startTurnTimer()

        // Point the bridge at THIS conversation's server (restarts it if the
        // target changed — same instructions whatever the address).
        if let err = await ModelRouter.shared.prepare(for: model, settings: settings,
                                                      serverURL: conversationServerURL) {
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

        let extraEnv = ModelRouter.shared.environment(for: model, settings: settings,
                                                      serverURL: conversationServerURL)

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
        bridgeDeathEpoch = myEpoch   // for non-closure callbacks (health monitor)
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
                    Task { await launchOrContinue(blocks, taskId: UUID()) }
                    return
                }
                appendNotice(.warning, L10n.t("compact_failed"))
            }
            isRunning = false
            let info = ResultInfo(
                isError: env.isError ?? false,
                text: env.result?.asString,     // use asString for plain-text result
                costUsd: env.totalCostUsd, durationMs: env.durationMs,
                numTurns: env.numTurns)
            appendItem(.result(info))
            if let c = env.totalCostUsd { totalCostUSD += c }

            // Record per-turn metrics for the diagnostics dashboard. */
            var tokensIn = 0, tokensOut = 0
            if let usageObj = env.usage?.asObject {
                tokensIn  = (usageObj["input_tokens"] ?? usageObj["prompt_tokens"] ?? .null).asNumber.flatMap { Int($0) } ?? 0
                tokensOut = (usageObj["output_tokens"] ?? usageObj["completion_tokens"] ?? .null).asNumber.flatMap { Int($0) } ?? 0
            }
            AppMetrics.shared.record(
                modelId: selectedModel.id,
                provider: selectedModel.provider.rawValue,
                tokensIn: Int(tokensIn), tokensOut: Int(tokensOut),
                costUSD: env.totalCostUsd ?? 0,
                latencyMs: env.durationMs ?? 0,
                isError: env.isError ?? false
            )
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
            AppLog.warn("stream", "unhandled stream type '\(env.type)'")
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
            AppLog.warn("stream", "unhandled stream_event delta type '\(delta["type"]?.asString ?? "nil")'")
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
        guard !autoCompactTriedThisTurn, env.isError == true else { return false }
        // env.result is JSONValue? — use asString (which handles strings/numbers/bools).
        let text = env.result?.asString?.lowercased() ?? ""
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
        // Redundant guard — the onExit closure already checks sessionEpoch,
        // but this prevents stale callbacks from any other path from corrupting state.
        guard sessionEpoch == bridgeDeathEpoch else { return }
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
        // Remember it so the server pickers can offer it. NEVER auto-switch:
        // a conversation stays on the server it was created with.
        if !settings.standbyServers.contains(where: { $0.url == server.url }) {
            settings.addStandbyServer(server.standbyServer)
        }
    }
}

extension ChatViewModel: OllamaDiscovery.ReachabilityDelegate {
    @MainActor
    func didChangeNetworkReachable(_ reachable: Bool) {
        if reachable {
            // Network back — rescan, refresh, and re-probe the bound server
            // (may lift the "server unavailable" block). No server switch.
            Task { await self.periodicScanner?.runScan(configuredServer: self.conversationServerURL) }
            Task { await self.refreshModels() }
            Task { await self.probeConversationServer() }
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

    /// Only Ollama models route through a local bridge; Anthropic ones don't.
    var usesBridge: Bool {
        let p = selectedModel.provider
        return p == .ollama || p == .ollamaNetwork
    }

    /// The bridge died while a turn was running: the in-flight request is gone.
    /// Close the turn with a clear error so the user can just resend.
    func turnBrokenByBridgeDeath() {
        let checkEpoch = sessionEpoch   // capture at call time
        guard isRunning, checkEpoch == sessionEpoch else { return } // stale callback from old epoch
        watchdog?.cancel()
        waitingHint = nil
        isRunning = false
        stopTurnTimer()
        appendNotice(.error, L10n.t("turn_lost_bridge_died"))
        statusLine = L10n.t("router_restarting")
        AppLog.write("session", "turn aborted: bridge process died mid-turn")
    }

    /// Stop the dead bridge and start a fresh one on the current model.
    func restartBridge() async -> String? {
        guard usesBridge else { return nil }
        let model = selectedModel
        ModelRouter.shared.shutdown()
        if let err = await ModelRouter.shared.prepare(for: model, settings: settings,
                                                      serverURL: conversationServerURL) { return err }
        ModelRouter.shared.startKeepAlive(port: ModelRouter.shared.activeBridgePort(settings: settings),
                                          healthPath: ModelRouter.shared.activeBridgeHealthPath(settings: settings))
        return nil
    }

    /// A turn is in flight — the health monitor must not restart the bridge now.
    var isTurnInFlight: Bool { isRunning }

    /// The current session epoch for rejecting stale health callbacks.
    var currentSessionEpoch: UUID { sessionEpoch }

    func routerDidRestart() {
        // The bridge really was restarted by restartBridge() before we get here,
        // so this only confirms the outcome to the user.
        Task {
            let isHealthy = await ModelRouter.shared.bridgeHealthy(settings: settings)
            await MainActor.run {
                statusLine = L10n.t(isHealthy ? "router_recovered" : "router_recovery_failed")
                if !isHealthy {
                    AppLog.write("health", "bridge still unhealthy after restart")
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

            let prepareErr = await ModelRouter.shared.prepare(for: currentModel, settings: settings,
                                                              serverURL: conversationServerURL)
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

// MARK: - Per-conversation server: probe, wait for return, change

extension ChatViewModel {
    /// Host part of the bound server, for display.
    var serverHost: String {
        URL(string: conversationServerURL)?.host ?? conversationServerURL
    }

    /// Is the bound server answering? Updates the block accordingly. No fallback:
    /// if it's down, the conversation waits for THIS server, not another one.
    func probeConversationServer() async {
        guard usesBridge else { serverUnavailable = false; return }
        let up = await OllamaClient.isReachable(baseURL: conversationServerURL)
        if up {
            if serverUnavailable {
                serverUnavailable = false
                statusLine = L10n.t("server_back", serverHost)
                await refreshModels()
            }
            serverWatchTask?.cancel()
        } else if !serverUnavailable {
            serverUnavailable = true
            statusLine = L10n.t("server_waiting", serverHost)
            startServerWatch()
        }
    }

    /// While blocked, quietly re-probe the bound server so the conversation
    /// unblocks by itself the moment the server reappears.
    func startServerWatch() {
        serverWatchTask?.cancel()
        serverWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, self.serverUnavailable else { return }
                if await OllamaClient.isReachable(baseURL: self.conversationServerURL) {
                    await MainActor.run {
                        self.serverUnavailable = false
                        self.statusLine = L10n.t("server_back", self.serverHost)
                    }
                    await self.refreshModels()
                    return
                }
            }
        }
    }

    /// Switch this conversation to another server, mid-course. The claude
    /// session keeps running: it resends the FULL history on every request, so
    /// the new server receives the whole conversation on the next message.
    func changeServer(to url: String) async {
        guard !isRunning else {
            statusLine = L10n.t("server_change_busy")
            return
        }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != conversationServerURL else { return }
        conversationServerURL = trimmed
        settings.ollamaBaseURL = trimmed        // seed for future conversations
        serverUnavailable = false
        serverWatchTask?.cancel()
        // Retarget: prepare() will restart the bridge at next send since the
        // target URL changed; shutting down now makes it immediate and frees
        // the old connection.
        ModelRouter.shared.shutdown()
        await refreshModels()
        await probeConversationServer()
        if !serverUnavailable {
            statusLine = L10n.t("server_changed", serverHost)
            AppLog.write("session", "server changed to \(trimmed) — full history goes there next turn")
        }
        persistIfNeeded()
    }

    private func persistIfNeeded() {
        if currentConversationId != nil { persist() }
    }
}

// MARK: - Secret redactor (simple pattern-based sanitization for stderr logs)

private enum secretRedactor {
    // Regexes compiled once; re-used on every call to avoid per-call allocation/compilation.
    private static let compiled = { () -> [NSRegularExpression] in
        var result: [NSRegularExpression] = []
        for pat in [
            "sk-[A-Za-z0-9]{20,}",
            "sk-ant-[A-Za-z0-9_-]{20,}",  // P1: Anthropic API keys (audit finding)
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
