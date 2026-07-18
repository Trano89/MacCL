import Foundation
import Combine
import AppKit

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
    // Token accounting, fed by the `usage` block of each turn's result.
    /// ≈ the conversation's current context footprint (last turn, prompt+cache+output).
    @Published var contextTokens: Int = 0
    /// Cumulative tokens read (prompt + cache) and generated over the conversation.
    @Published var totalInputTokens: Int = 0
    @Published var totalOutputTokens: Int = 0
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
        itemCounter += 1
        return "item-\(itemCounter)"
    }
    /// Circular buffer for stderr text — rotates every 2 KB to avoid holding sensitive data.
    private var stderrTail: String = ""
    private let maxStderrTail = 1024
    private var sawResultSinceLastTurn = false
    /// Results still expected for in-band commands the APP sent (/effort …).
    /// Those turns are plumbing: their result becomes a small notice instead of
    /// closing the user's turn.
    private var pendingInternalResults = 0
    private var watchdog: Task<Void, Never>?
    private var receivedContentThisTurn = false
    private var didInterrupt = false
    // Live-streaming state (partial messages): index of the in-progress
    // assistant text item, and whether this message's thinking already streamed.
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
    /// Detects foreground ↔ background transitions to re-probe the bound server.
    private let lifecycleObserver = AppLifecycleObserver()
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
        // Wire the session FIRST: an unwired session runs `claude` and drops
        // every event on the floor — the app looks alive and shows nothing.
        wire()
        reachabilityMonitor = OllamaDiscovery.ReachabilityMonitor(delegate: self)
        reachabilityMonitor?.startMonitoring()
        // The sweep now covers the whole subnet (~254 probes, ~3 s) instead of a
        // token sixteen addresses, so it must run far less often: every 30 s it
        // would look like a port scanner to the network. On-demand "Scan" and the
        // reachability trigger cover the impatient cases.
        periodicScanner = OllamaDiscovery.PeriodicScanner(interval: 300, delegate: self)
        // Start the background scanner immediately.
        periodicScanner?.start(configuredServer: settings.ollamaBaseURL)
        // Wire up lifecycle observer (foreground/background).
        lifecycleObserver.delegate = self
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
    var isBlockedByServer: Bool { usesOllama && serverUnavailable }

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
            // Abort the current turn but keep the session alive — and KEEP
            // LISTENING: the same session carries the next turn, so muting it
            // here (the old epoch reset) made every turn after an interrupt
            // silently disappear. `didInterrupt` swallows the aborted result.
            didInterrupt = true
            session.interrupt()
            resumeOnNextStart = true  // fallback: if the process later dies, resume
        } else {
            session.stop()
        }
        isRunning = false
        pendingInternalResults = 0   // an eaten command result must not swallow a real one
        statusLine = L10n.t("interrupted")
        stopTurnTimer()
    }

    /// Change the reasoning effort — live: the running session receives
    /// `/effort <level>` in-band and confirms with a small notice.
    func applyEffort(_ level: EffortLevel) {
        settings.effortLevel = level
        guard session.isRunning else { return }   // next launch sends it anyway
        pendingInternalResults += 1
        session.sendCommand("/effort \(level.cliValue)")
    }

    func newConversation() {
        watchdog?.cancel()
        waitingHint = nil
        pendingInternalResults = 0
        session.stop()
        session = ClaudeSession()   // replacing the object orphans old callbacks
        wire()
        items = []
        toolIndex.removeAll()
        sessionId = nil
        currentConversationId = nil
        conversationCreatedAt = Date()
        resumeOnNextStart = false
        totalCostUSD = 0
        contextTokens = 0
        totalInputTokens = 0
        totalOutputTokens = 0
        currentReasoning = ""
        streamingTextIndex = nil
        streamedThinkingThisMessage = false
        isRunning = false
        statusLine = L10n.t("new_conversation")
        conversationInstructions = ""
        currentGroup = nil
        stopTurnTimer()
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
        pendingInternalResults = 0
        session.stop()
        session = ClaudeSession()
        wire()                     // rewire with fresh epoch
        items = convo.items
        // Restart the id counter past every restored "item-N": a fresh counter
        // would re-issue item-1, item-2… and duplicate Identifiable ids make
        // SwiftUI's ForEach rendering undefined (rows that never update).
        itemCounter = items.compactMap { Int64($0.id.dropFirst("item-".count)) }.max() ?? 0
        rebuildToolIndex()
        currentConversationId = convo.id
        sessionId = convo.id
        conversationCreatedAt = convo.createdAt
        totalCostUSD = convo.totalCostUSD
        contextTokens = convo.contextTokens ?? 0
        totalInputTokens = convo.totalInputTokens ?? 0
        totalOutputTokens = convo.totalOutputTokens ?? 0
        resumeOnNextStart = true // next message continues the persisted session
        currentReasoning = ""
        streamingTextIndex = nil
        streamedThinkingThisMessage = false
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
            totalCostUSD: totalCostUSD,
            contextTokens: contextTokens,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens
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

    private func launchOrContinue(_ blocks: [[String: Any]]) async {
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

        // Check THIS conversation's server is up and speaks the Messages API
        // before we commit the turn to it.
        if let err = await ModelRouter.shared.prepare(for: model, settings: settings,
                                                      serverURL: conversationServerURL) {
            appendNotice(.error, err)
            isRunning = false
            statusLine = L10n.t("server_error")
            return
        }

        let extraEnv = ModelRouter.shared.environment(for: model, serverURL: conversationServerURL)

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
            // (This is where the old epoch was reset WITHOUT rewiring — which
            // silently discarded every event of every freshly started session.
            // With identity-based wiring there is nothing to reset.)
            let resumed = resumeOnNextStart
            AppLog.write("session", "start model=\(model.modelArg) provider=\(model.provider.rawValue) "
                         + "base=\(extraEnv["ANTHROPIC_BASE_URL"] ?? "anthropic") "
                         + "effort=\(settings.effortLevel.cliValue) resume=\(resumed)")
            // Reasoning level travels in-band, not as a launch flag: applied
            // before the first turn, changeable any time via the effort button.
            let preCommands = ["/effort \(settings.effortLevel.cliValue)"]
            pendingInternalResults += preCommands.count
            try session.start(config: config, firstContent: blocks,
                              resume: resumed, preCommands: preCommands)
            resumeOnNextStart = false
            // One compact line in the transcript; the full copy-pastable command
            // lives in the notice's detail (tooltip + expandable).
            let host = URL(string: conversationServerURL)?.host ?? "anthropic"
            let where_ = model.provider == .anthropic ? "Anthropic" : host
            appendNotice(.info,
                         "$ claude --model \(model.modelArg) · \(where_)"
                         + (resumed ? " · resume" : ""),
                         detail: launchCommandLine(config: config, resumed: resumed))
        } catch {
            appendNotice(.error, L10n.t("launch_failed"))
            isRunning = false
        }
    }

    /// The literal terminal command this session runs — same builder as the
    /// real spawn, so the display can never drift from what actually executes.
    private func launchCommandLine(config: SessionConfig, resumed: Bool) -> String {
        let env = config.extraEnv
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let cmd = "claude " + config.cliArguments(resume: resumed, forDisplay: true)
            .joined(separator: " ")
        let prefix = env.isEmpty ? "" : env + " "
        return "$ cd \"\(config.workingDirectory)\"\n$ \(prefix)\(cmd)\n> /effort \(config.effort.cliValue)"
    }

    // MARK: - Event handling

    private func wire() {
        // Staleness by OBJECT IDENTITY, nothing else: a callback belongs to the
        // ClaudeSession it was wired on, and dies the moment the VM moves on to
        // a new one (newConversation/load replace the object). The old epoch
        // token had to be manually re-synced after every reset — forget once
        // and the session went deaf, which is exactly what kept happening.
        let s = session
        session.onEvent = { [weak self] env in
            guard let self, self.session === s else { return }
            self.handle(env)
        }
        session.onStderr = { [weak self] text in
            guard let self, self.session === s else { return }
            self.handleStderr(text)
        }
        session.onExit = { [weak self] code in
            guard let self, self.session === s else { return }
            self.handleExit(code)
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
            // Live context gauge: every assistant event carries this API call's
            // usage (verified). Latest wins — independent of the result plumbing,
            // so the gauge moves even mid-turn during long tool loops.
            if let u = env.message?.usage {
                let footprint = (u["input_tokens"]?.asInt ?? 0)
                    + (u["cache_read_input_tokens"]?.asInt ?? 0)
                    + (u["cache_creation_input_tokens"]?.asInt ?? 0)
                    + (u["output_tokens"]?.asInt ?? 0)
                if footprint > 0 { contextTokens = footprint }
            }
            for block in env.message?.content ?? [] {
                switch block {
                case .text(let t) where !t.isEmpty:
                    // If this text streamed live, replace the in-progress item
                    // with the canonical version instead of duplicating it.
                    if let idx = streamingTextIndex, idx < items.count {
                        var copy = items[idx]
                        copy.kind = .assistantText(t)
                        items.replaceSubrange(idx...idx, with: [copy])
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
            // A result for an app-sent command (/effort …) is plumbing, not the
            // user's turn: acknowledge it quietly and leave the turn running.
            // Match on CONTENT, not just the counter: when /effort is sent while
            // a turn is in flight, the REAL turn's result arrives first — a bare
            // counter ate it (turn never closed, tokens never counted) and then
            // promoted the /effort ack to "the result".
            if let text = env.result, text.hasPrefix("Set effort level") {
                if pendingInternalResults > 0 { pendingInternalResults -= 1 }
                appendNotice(.info, text)
                return
            }
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
            // Without this the 1 s ticker publishes (and wakes SwiftUI) forever
            // after the first turn of the app's lifetime.
            stopTurnTimer()
            let info = ResultInfo(isError: env.isError ?? false, text: env.result,
                                  costUsd: env.totalCostUsd, durationMs: env.durationMs,
                                  numTurns: env.numTurns)
            appendItem(.result(info))
            if let c = env.totalCostUsd { totalCostUSD += c }
            if let u = env.usage {
                let inTok = u["input_tokens"]?.asInt ?? 0
                let cacheRead = u["cache_read_input_tokens"]?.asInt ?? 0
                let cacheCreate = u["cache_creation_input_tokens"]?.asInt ?? 0
                let outTok = u["output_tokens"]?.asInt ?? 0
                totalInputTokens += inTok + cacheRead + cacheCreate
                totalOutputTokens += outTok
                // What the NEXT turn will have to carry — this is the number
                // that says when compacting is worth it.
                contextTokens = inTok + cacheRead + cacheCreate + outTok
            }
            statusLine = (env.isError ?? false) ? L10n.t("done_error") : L10n.t("ready")
            persist()
            // Roll the model's residency window so the NEXT turn starts hot.
            // Without this, Ollama's default keep_alive (5 min) unloads the
            // model between turns and every reply after a pause costs a full
            // reload — the "simple question takes forever" experience.
            if usesOllama {
                let m = selectedModel.modelArg, server = conversationServerURL
                Task.detached { await OllamaClient.warmUp(model: m, baseURL: server) }
            }
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
    /// User-requested compaction (token chip): same `/compact` as the automatic
    /// path, but as a visible turn the user chose to spend.
    func compactContext() {
        guard canSend, !items.isEmpty else { return }
        isRunning = true
        statusLine = L10n.t("compacting")
        startTurnTimer()
        appendNotice(.info, L10n.t("compact_notice"))
        session.send(content: [["type": "text", "text": "/compact"]])
    }

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
        stopTurnTimer()
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
        pendingInternalResults = 0
        persist()
    }

    // MARK: - Item helpers

    private func appendItem(_ kind: ChatItem.Kind) {
        items.append(ChatItem(id: nextItemId(), kind: kind))
    }

    private func appendNotice(_ level: Notice.Level, _ text: String, detail: String? = nil) {
        appendItem(.notice(Notice(level: level, text: text, detail: detail)))
    }

    private func updateTool(_ id: String, _ mutate: (inout ToolActivity) -> Void) {
        guard let idx = toolIndex[id], idx < items.count,
              case .tool(var act) = items[idx].kind else { return }
        mutate(&act)
        var copy = items[idx]
        copy.kind = .tool(act)
        items.replaceSubrange(idx...idx, with: [copy])
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

// MARK: - App lifecycle (background/foreground)

extension ChatViewModel: AppLifecycleDelegate {
    func appDidEnterBackground() {
        // Nothing to do: `claude` talks straight to Ollama over HTTP. There is no
        // local bridge process left to die while we're away, which is what all the
        // "ran two minutes then nothing" healing used to be about.
    }

    func appDidBecomeActive() {
        // The bound server may have gone away while we were backgrounded (laptop
        // left the network, machine asleep). Re-probe — that either lifts or
        // raises the block, with no server switch behind the user's back.
        Task { await self.probeConversationServer() }
        Task { await self.refreshModels() }
    }
}

// MARK: - Provider

extension ChatViewModel {
    /// True when the selected model lives on an Ollama server rather than at
    /// Anthropic — i.e. when the conversation is bound to a server at all.
    var usesOllama: Bool {
        let p = selectedModel.provider
        return p == .ollama || p == .ollamaNetwork
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
        guard usesOllama else { serverUnavailable = false; return }
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
        // Retargeting is now just this assignment: the next turn's environment is
        // computed from `conversationServerURL`, so there is no bridge left to
        // point somewhere else — and no way for a request to reach the old server.
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
