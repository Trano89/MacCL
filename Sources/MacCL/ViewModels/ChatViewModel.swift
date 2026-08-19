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
    /// Cumulative tokens read (prompt + cache) and generated over the conversation,
    /// as settled by each turn's authoritative `result`.
    @Published var totalInputTokens: Int = 0
    @Published var totalOutputTokens: Int = 0
    /// What the turn in flight has spent so far, from the `usage` of each
    /// assistant event. Added to the settled totals for display, then folded in
    /// (and reset) when the turn's result arrives — so the figures move during a
    /// long tool loop instead of jumping only at the very end.
    @Published var liveTurnInputTokens: Int = 0
    @Published var liveTurnOutputTokens: Int = 0
    var displayedInputTokens: Int { totalInputTokens + liveTurnInputTokens }
    var displayedOutputTokens: Int { totalOutputTokens + liveTurnOutputTokens }
    /// Context ceiling of the conversation's model, when it reports one — what
    /// `contextTokens` is actually filling up.
    var contextCeiling: Int? { selectedModel.contextMax }
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
    /// When the turn last showed any sign of life — drives the idle hint.
    private var lastEventAt = Date()
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

    // MARK: Sub-agents (Task tool) — right-hand panel

    /// A sub-agent as the panel shows it, derived from the Task tool items.
    struct AgentInfo: Identifiable {
        let id: String            // the Task tool_use id
        let description: String
        let type: String?
        let prompt: String        // the agent's full instructions
        let isRunning: Bool
        let isError: Bool
        let resultText: String?
    }

    /// What one sub-agent has actually done, assembled from its own stream
    /// events. This is the same material the main transcript is built from —
    /// reasoning, prose, tool calls — just scoped to one agent.
    struct AgentRun {
        /// The model its requests really carried, straight off the wire. Not
        /// the definition on disk, which may have been edited since it started,
        /// and which says nothing about what a running agent is using.
        var model: String?
        var reasoning: String = ""
        var text: String = ""
        var tools: [ToolActivity] = []
        /// toolUseId → index into `tools`, so a result can find its call.
        var toolIndex: [String: Int] = [:]
        /// This message's thinking / text already arrived as deltas — the
        /// complete block that follows would otherwise be appended a second
        /// time. (Today the CLI forwards whole blocks for sub-agents rather
        /// than deltas, so these stay false; they cost nothing and mean a
        /// future that does stream won't duplicate every sentence.)
        var streamedThinking = false
        var streamedText = false

        /// Model and machine, split off the `model@machine` routing suffix.
        var modelName: String? {
            model.map { AgentDefinition.splitModelField($0).model }
        }
        var machineName: String? {
            guard let model else { return nil }
            let server = AgentDefinition.splitModelField(model).serverName
            return server.isEmpty ? nil : server
        }
    }

    /// The model THIS conversation's sub-agents think with, as `model` or
    /// `model@machine`. Empty = they inherit the conversation's own model.
    ///
    /// It reaches the CLI as `CLAUDE_CODE_SUBAGENT_MODEL`, which the resolver
    /// checks before anything else — so it covers every sub-agent, including
    /// the types Claude Code spawns on its own and which no file on disk
    /// describes.
    @Published var subagentModel: String
    @Published var showAgentsPanel = false
    @Published var selectedAgentId: String?
    /// Live state per sub-agent, keyed by the Task tool_use id.
    @Published var agentRuns: [String: AgentRun] = [:]

    /// Every sub-agent of this conversation, transcript order.
    var agents: [AgentInfo] {
        items.compactMap { item in
            guard case .tool(let a) = item.kind, a.isDelegation else { return nil }
            return AgentInfo(id: a.toolUseId,
                             description: a.input["description"]?.asString ?? a.headline,
                             type: a.input["subagent_type"]?.asString,
                             prompt: a.input["prompt"]?.asString ?? "",
                             isRunning: a.isRunning,
                             isError: a.isError,
                             resultText: a.resultText)
        }
    }

    /// Sub-agents still working — drives the badge on the panel toggle. Takes
    /// the CLI's own task protocol when it has spoken, since a Task card stays
    /// "running" until its tool_result lands, which can lag the real state.
    var runningAgentCount: Int {
        backgroundTasks.isEmpty ? agents.filter(\.isRunning).count : runningTaskCount
    }

    // MARK: - Conversations left working in the background

    /// A conversation whose `claude` process keeps running while the user looks
    /// at another one. Its events pile up here and are replayed on return, so
    /// the work continues and the transcript comes back complete.
    @MainActor
    private final class ParkedConversation {
        let session: ClaudeSession
        var buffer: [StreamEnvelope] = []
        var stderr = ""
        var exitCode: Int32?
        init(session: ClaudeSession) { self.session = session }
    }

    private var parked: [String: ParkedConversation] = [:]
    /// Conversations still working while you are elsewhere — the sidebar marks them.
    @Published private(set) var workingConversationIds: Set<String> = []

    /// Leave the current conversation running instead of killing it. Switching
    /// used to call `session.stop()`, so moving to another conversation aborted
    /// the turn: coming back showed a transcript frozen mid-sentence with
    /// nothing left running. Returns true when a session was parked.
    private func parkCurrentIfWorking() -> Bool {
        guard let id = currentConversationId, isRunning, session.isRunning else { return false }
        flushStream()
        persist()
        let parkedConv = ParkedConversation(session: session)
        // Its own callbacks: `wire()` keys on object identity, so the moment we
        // swap `session` the original ones would go deaf and drop everything.
        session.onEvent = { [weak parkedConv] env in parkedConv?.buffer.append(env) }
        session.onStderr = { [weak parkedConv] text in
            guard let parkedConv else { return }
            parkedConv.stderr = String((parkedConv.stderr + text).suffix(2048))
        }
        session.onExit = { [weak parkedConv] code in parkedConv?.exitCode = code }
        parked[id] = parkedConv
        workingConversationIds.insert(id)
        session = ClaudeSession()          // the next conversation gets a fresh one
        AppLog.write("session", "conversation \(id) parked — still working in background")
        return true
    }

    /// Re-adopt a parked conversation: its process is still the live one, and
    /// every event received while away is replayed so the transcript catches up
    /// in one go, then keeps streaming normally.
    private func adoptParkedIfAny(_ id: String) {
        guard let parkedConv = parked.removeValue(forKey: id) else { return }
        workingConversationIds.remove(id)
        session = parkedConv.session
        wire()
        isRunning = parkedConv.exitCode == nil && parkedConv.session.isRunning
        if isRunning { startTurnTimer() }
        if !parkedConv.stderr.isEmpty { stderrTail = parkedConv.stderr }
        for env in parkedConv.buffer { handle(env) }
        if let code = parkedConv.exitCode { handleExit(code) }
        AppLog.write("session",
                     "conversation \(id) resumed — \(parkedConv.buffer.count) events replayed")
    }

    /// Kill every background conversation (app quit, or one being deleted).
    private func stopParked(_ id: String? = nil) {
        if let id {
            parked.removeValue(forKey: id)?.session.stop()
            workingConversationIds.remove(id)
        } else {
            for (_, parkedConv) in parked { parkedConv.session.stop() }
            parked.removeAll()
            workingConversationIds.removeAll()
        }
    }

    /// Open the panel focused on one agent (the link in the transcript).
    func openAgent(_ id: String) {
        selectedAgentId = id
        showAgentsPanel = true
    }

    /// Events emitted INSIDE a sub-agent: feed its activity log — never the main
    /// transcript, which they used to pollute (interleaved text and tool cards
    /// appearing to come from the main conversation).
    private func handleAgentEvent(parent: String, _ env: StreamEnvelope) {
        receivedContentThisTurn = true
        waitingHint = nil
        lastEventAt = Date()      // a sub-agent speaking is the turn being alive
        var run = agentRuns[parent] ?? AgentRun()

        switch env.type {
        case "assistant":
            // Every assistant event names the model that answered it — the only
            // trustworthy answer to "which brain is this agent using".
            if let model = env.message?.model, !model.isEmpty { run.model = model }
            for block in env.message?.content ?? [] {
                switch block {
                case .text(let t) where !t.isEmpty:
                    if run.streamedText {
                        run.streamedText = false   // already shown live
                    } else {
                        run.text += run.text.isEmpty ? t : "\n\n" + t
                    }
                case .thinking(let t) where !t.isEmpty:
                    if run.streamedThinking {
                        run.streamedThinking = false   // already shown live
                    } else {
                        run.reasoning += run.reasoning.isEmpty ? t : "\n\n" + t
                    }
                case .toolUse(let id, let name, let input):
                    let activity = ToolActivity(toolUseId: id, name: name, input: input)
                    run.toolIndex[id] = run.tools.count
                    run.tools.append(activity)
                default:
                    break
                }
            }
        case "user":
            // The sub-agent's own tool results, so its cards close like the
            // main conversation's instead of spinning forever.
            for block in env.message?.content ?? [] {
                if case .toolResult(let tid, let text, let isErr) = block,
                   let idx = run.toolIndex[tid], idx < run.tools.count {
                    run.tools[idx].resultText = text
                    run.tools[idx].isError = isErr
                    run.tools[idx].isRunning = false
                }
            }
        case "stream_event":
            // Live deltas: a slow local model must visibly be thinking, not
            // merely "running" for two minutes.
            guard let event = env.event,
                  event["type"]?.asString == "content_block_delta",
                  let delta = event["delta"] else { break }
            switch delta["type"]?.asString {
            case "thinking_delta":
                if let t = delta["thinking"]?.asString, !t.isEmpty {
                    run.reasoning += t
                    run.streamedThinking = true
                }
            case "text_delta":
                if let t = delta["text"]?.asString, !t.isEmpty {
                    run.text += t
                    run.streamedText = true
                }
            default:
                break
            }
        default:
            break
        }

        agentRuns[parent] = run
        // Keep the CLI's own task entry in step, so the panel header has a live
        // line without re-deriving it from the run.
        if let idx = backgroundTasks.firstIndex(where: { $0.toolUseId == parent }) {
            backgroundTasks[idx].lastLine = run.tools.last.map { "⚒ \($0.name)" }
        }
    }

    // MARK: - Background tasks (the CLI's own sub-agent protocol)

    /// A sub-agent as the CLI itself reports it, through `system/task_started`,
    /// `task_updated` and `task_notification`. This is what actually answers
    /// "is an agent running, and where is it?" — the Task tool card alone only
    /// says one was launched.
    struct BackgroundTask: Identifiable, Equatable {
        let id: String              // task_id
        let toolUseId: String?
        var description: String
        var subagentType: String?
        var status: String          // "running" until the CLI says otherwise
        var startedAt: Date
        var lastLine: String?
        var summary: String?
        var isRunning: Bool { status == "running" }
    }

    @Published var backgroundTasks: [BackgroundTask] = []

    /// Sub-agents the CLI reports as still working.
    var runningTaskCount: Int { backgroundTasks.filter(\.isRunning).count }

    private func handleTaskEvent(_ env: StreamEnvelope) {
        switch env.subtype {
        case "task_started":
            guard let id = env.taskId else { return }
            let task = BackgroundTask(id: id, toolUseId: env.toolUseId,
                                      description: env.description ?? L10n.t("agents_title"),
                                      subagentType: env.subagentType,
                                      status: "running", startedAt: Date(),
                                      lastLine: nil, summary: nil)
            if let idx = backgroundTasks.firstIndex(where: { $0.id == id }) {
                backgroundTasks[idx] = task
            } else {
                backgroundTasks.append(task)
            }
        case "task_updated":
            guard let id = env.taskId,
                  let idx = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
            if let s = env.patch?["status"]?.asString { backgroundTasks[idx].status = s }
        case "task_notification":
            guard let id = env.taskId,
                  let idx = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
            if let s = env.status { backgroundTasks[idx].status = s }
            if let s = env.summary { backgroundTasks[idx].summary = s }
        default:
            break
        }
    }

    /// The Ollama server THIS conversation is bound to. Chosen when the
    /// conversation is created, persisted with it, changeable mid-conversation.
    /// Never rewritten behind the user's back.
    @Published var conversationServerURL: String
    /// True while the conversation's server doesn't answer: sending is blocked
    /// (with a visible banner) until the server comes back — no localhost fallback.
    @Published var serverUnavailable = false
    /// Re-probes the bound server while it's unavailable, to unblock automatically.
    private var serverWatchTask: Task<Void, Never>?
    /// The base URL the LIVE `claude` process was spawned with. A child's
    /// environment is fixed at exec, so this is the only honest answer to
    /// "where is this session actually sending its requests".
    private var sessionBackendURL: String?

    init(settings: AppSettings) {
        self.settings = settings
        // Seed new conversations with the last server used (pure default — the
        // new-conversation sheet asks explicitly every time).
        conversationServerURL = settings.ollamaBaseURL
        subagentModel = settings.subagentModel
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
            Task { @MainActor in
                self?.session.stop()
                self?.stopParked()
                // The loopback listener would die with the process anyway; closing
                // it deliberately keeps `stop()` a real code path rather than a
                // method nothing ever calls.
                AgentRouter.shared.stop()
            }
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

    /// The machine this conversation's working directory lives on — nil when
    /// it's this Mac. Resolved from the store on every read so a host deleted
    /// mid-conversation degrades to "local" instead of dangling.
    var remoteHost: SSHHost? {
        SSHHostStore.shared.host(id: settings.workLocationHostId)
    }

    /// The conversation points at an SSH host that no longer exists in the
    /// settings — the working directory is a remote path with nothing to reach it.
    var hasOrphanedHost: Bool {
        !settings.workLocationHostId.isEmpty && remoteHost == nil
    }

    var canSend: Bool {
        let hasText = !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachments.isEmpty) && !isRunning && !isBlockedByServer
    }

    /// Compaction needs something to compact and a free turn — deliberately NOT
    /// `canSend`, which also demands a composed message. Borrowing it made the
    /// "compact now" button do nothing whenever the composer was empty, which is
    /// exactly when you reach for it.
    var canCompact: Bool {
        !items.isEmpty && !isRunning && !isBlockedByServer
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
        transientRetries = 0
        if currentConversationId == nil {
            let newId = UUID().uuidString
            currentConversationId = newId
            sessionId = newId
            conversationCreatedAt = Date()
        }
        appendItem(.user(text: text, attachments: atts))
        // Images and text files travel inside the message, so they work anywhere.
        // A `.other` attachment is sent as a PATH for the agent to Read — and
        // that path exists on this Mac, not on the machine the agent runs on.
        if remoteHost != nil {
            let unreachable = atts.filter { $0.kind == .other }
            if !unreachable.isEmpty {
                appendNotice(.warning,
                             L10n.t("ssh_local_attachment",
                                    unreachable.map(\.filename).joined(separator: ", ")))
            }
        }
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
        // Park a working conversation rather than aborting it — starting a new
        // one must not cost you the turn the previous one was in the middle of.
        if !parkCurrentIfWorking() {
            session.stop()
            session = ClaudeSession()   // replacing the object orphans old callbacks
        }
        wire()
        items = []
        toolIndex.removeAll()
        sessionId = nil
        currentConversationId = nil
        conversationCreatedAt = Date()
        resumeOnNextStart = false
        totalCostUSD = 0
        contextTokens = 0
        liveTurnInputTokens = 0
        liveTurnOutputTokens = 0
        discardStreamBuffers()
        totalInputTokens = 0
        totalOutputTokens = 0
        agentRuns = [:]
        showAgentsPanel = false
        selectedAgentId = nil
        currentReasoning = ""
        streamingTextIndex = nil
        streamedThinkingThisMessage = false
        isRunning = false
        statusLine = L10n.t("new_conversation")
        conversationInstructions = ""
        subagentModel = settings.subagentModel
        currentGroup = nil
        stopTurnTimer()
        // The new-conversation sheet sets the server right after this call;
        // until then, clear any stale block from the previous conversation.
        serverUnavailable = false
        serverWatchTask?.cancel()
        sessionBackendURL = nil
    }

    /// Load a conversation from history. Continuing it resumes the claude session.
    func load(_ summary: ConversationSummary) {
        guard let convo = ConversationStore.shared.load(summary.id) else { return }
        watchdog?.cancel()
        waitingHint = nil
        pendingInternalResults = 0
        // Leave a working conversation running in the background; we re-adopt it
        // at the end of this method if the one being opened IS that conversation.
        if !parkCurrentIfWorking() {
            session.stop()
            session = ClaudeSession()
        }
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
        liveTurnInputTokens = 0
        liveTurnOutputTokens = 0
        discardStreamBuffers()
        totalInputTokens = convo.totalInputTokens ?? 0
        totalOutputTokens = convo.totalOutputTokens ?? 0
        agentRuns = [:]
        showAgentsPanel = false
        selectedAgentId = nil
        resumeOnNextStart = true // next message continues the persisted session
        currentReasoning = ""
        streamingTextIndex = nil
        streamedThinkingThisMessage = false
        isRunning = false
        statusLine = L10n.t("conversation_loaded")
        // Restore the conversation's own parameters so a follow-up runs with the
        // exact same launch configuration (server, model, cwd, permissions, effort).
        settings.workingDirectory = convo.workingDirectory
        // …including WHICH machine that directory is on. A host the user has
        // since deleted falls back to local rather than pointing at nothing:
        // remoteHost() re-checks the store and the banner explains the gap.
        settings.workLocationHostId = convo.sshHostId ?? ""
        // Its bound server first (older files: fall back to the last-used one) —
        // the model list depends on it.
        conversationServerURL = convo.serverURL ?? settings.ollamaBaseURL
        serverUnavailable = false
        serverWatchTask?.cancel()
        sessionBackendURL = nil
        conversationInstructions = convo.instructions ?? ""
        subagentModel = convo.subagentModel ?? ""
        currentGroup = convo.group
        if let pm = convo.permissionMode { settings.permissionModeRaw = pm }
        if let ef = convo.effort { settings.effortLevelRaw = ef }
        // Restore the conversation's model FIRST; refreshModels() then keeps it
        // even when its server is down (the conversation just waits).
        settings.selectedModelId = convo.modelId
        // Was this conversation still working in the background? Take its live
        // process back and replay everything that happened while you were away,
        // so it reappears complete and keeps streaming. Last, so it applies on
        // top of the freshly restored state.
        adoptParkedIfAny(convo.id)
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
        stopParked(summary.id)      // never leave an orphan process behind
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
            sshHostId: settings.workLocationHostId.isEmpty ? nil : settings.workLocationHostId,
            permissionMode: settings.permissionModeRaw,
            effort: settings.effortLevelRaw,
            serverURL: conversationServerURL,
            instructions: conversationInstructions.isEmpty ? nil : conversationInstructions,
            subagentModel: subagentModel.isEmpty ? nil : subagentModel,
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
        lastEventAt = Date()
        // Runs for the WHOLE turn, not just its opening. The old version fired
        // once, at 5 s and 25 s, and only while nothing had arrived yet: after
        // the first token it went quiet for good. So a turn that spoke, then
        // delegated to a sub-agent for ten minutes, or sat re-evaluating a huge
        // prompt between two tool calls, showed a pulsing dot and nothing else
        // while the GPU was plainly busy. Silence is now reported whenever it
        // happens, and says what it is waiting on.
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.isRunning else { return }
                let idle = Date().timeIntervalSince(self.lastEventAt)
                guard idle >= 6 else {
                    if self.waitingHint != nil { self.waitingHint = nil }
                    continue
                }
                let subject = self.receivedContentThisTurn
                    ? self.idleSubject()
                    : (model.provider == .ollama ? L10n.t("waiting_local", model.name)
                                                 : L10n.t("waiting_remote", model.name))
                self.waitingHint = L10n.t("waiting_still",
                                          "\(subject) · \(Self.duration(idle))")
            }
        }
    }

    /// What the turn is actually waiting on, so the hint names something real.
    private func idleSubject() -> String {
        let running = agents.filter(\.isRunning)
        if running.count > 1 { return L10n.t("agents_n", "\(running.count)") }
        if let one = running.first { return one.description }
        for item in items.reversed() {
            if case .tool(let act) = item.kind, act.isRunning { return act.name }
        }
        return selectedModel.name
    }

    /// 95 → "1 min 35 s", 40 → "40 s".
    private static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s"
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

    /// The effort to actually ask for.
    ///
    /// Claude Code forwards the level verbatim as `output_config.effort`, and
    /// several Ollama chat templates validate it and `raise_exception` on
    /// anything outside their own list — an HTTP 500 that kills the turn.
    /// Qwen3.8 accepts xhigh, medium and low only, so `max` fails and so does
    /// the CLI's own default of `high`. Sub-agents inherit the session's level,
    /// which is why the sub-agent model's template constrains it too — that is
    /// the model whose replies were failing.
    ///
    /// Returns the level to send, plus the original one when it had to change.
    private func effectiveEffort() async -> (EffortLevel, EffortLevel?) {
        let wanted = settings.effortLevel
        guard selectedModel.provider != .anthropic else { return (wanted, nil) }

        var allowed = await OllamaClient.supportedReasoningEfforts(
            model: selectedModel.modelArg, baseURL: conversationServerURL)

        // Sub-agents ride on the same session-level effort.
        let sub = AgentDefinition.splitModelField(
            subagentModel.trimmingCharacters(in: .whitespaces)).model
        if !sub.isEmpty,
           let subAllowed = await OllamaClient.supportedReasoningEfforts(
               model: sub, baseURL: conversationServerURL) {
            allowed = allowed.map { $0.intersection(subAllowed) } ?? subAllowed
        }

        guard let allowed, !allowed.isEmpty, !allowed.contains(wanted.cliValue) else {
            return (wanted, nil)   // unconstrained, or already acceptable
        }
        // Closest capability the templates will take, ties resolved upward.
        let best = EffortLevel.allCases
            .filter { allowed.contains($0.cliValue) }
            .min { a, b in
                let da = abs(a.bars - wanted.bars), db = abs(b.bars - wanted.bars)
                return da == db ? a.bars > b.bars : da < db
            }
        guard let best, best != wanted else { return (wanted, nil) }
        AppLog.write("session", "effort \(wanted.cliValue) unsupported by the model template — using \(best.cliValue)")
        return (best, wanted)
    }

    private func launchOrContinue(_ blocks: [[String: Any]]) async {
        // Which machine runs the agent. Local needs a `claude` on THIS Mac;
        // remote needs one over there instead — checked further down, once,
        // when the session actually has to be spawned.
        let remote = remoteHost
        // The conversation records a host that has since been deleted. Running
        // it locally would point a remote path at this Mac's filesystem, so it
        // stops here and says which machine is missing.
        if remote == nil, !settings.workLocationHostId.isEmpty {
            appendNotice(.error, L10n.t("ssh_host_gone"))
            isRunning = false
            return
        }
        var claudePath = ""
        if remote == nil {
            guard let path = BinaryLocator.find("claude", override: settings.claudePathOverride) else {
                claudeAvailable = false
                appendNotice(.error, L10n.t("binary_not_found"))
                isRunning = false
                return
            }
            claudePath = path
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

        // Where `claude` will actually send its requests. Normally the
        // conversation's own server; the fan-out router only when a sub-agent
        // names another machine.
        let backend = await resolveBackendURL(for: model)
        var extraEnv = ModelRouter.shared.environment(for: model, serverURL: backend.url)
        // Part of the session's identity — which brain the delegated work uses —
        // so it belongs in the displayed command, not in the hidden plumbing.
        let subagent = subagentModel.trimmingCharacters(in: .whitespaces)
        if !subagent.isEmpty { extraEnv["CLAUDE_CODE_SUBAGENT_MODEL"] = subagent }

        if session.isRunning {
            // The live process holds the base URL it was spawned with, so a
            // sub-agent that has since moved machine cannot be honoured now.
            // Say it rather than dispatching the turn somewhere it won't work.
            if let launched = sessionBackendURL, launched != backend.url {
                appendNotice(.warning, L10n.t("router_needs_restart"))
            }
            session.send(content: blocks)
            return
        }

        // A remote session is about to be spawned: confirm the machine answers
        // and actually carries `claude` BEFORE the turn is committed to it.
        // Failing here costs one probe; failing later costs the user's message.
        var host = remote
        if var h = host {
            statusLine = L10n.t("ssh_connecting", h.label)
            switch await SSHClient.probe(h) {
            case .failure(let failure):
                appendNotice(.error, L10n.t("ssh_launch_failed", h.label) + " — " + failure.message)
                statusLine = L10n.t("ssh_unreachable", h.label)
                isRunning = false
                return
            case .success(let probe):
                guard probe.hasClaude else {
                    appendNotice(.error, SSHClient.Failure.claudeMissing.message)
                    statusLine = L10n.t("ssh_unreachable", h.label)
                    isRunning = false
                    return
                }
                // Pin the absolute path we just resolved: the streaming session
                // runs with a non-interactive PATH and must not re-guess.
                h.remoteClaudePath = probe.claudePath
                SSHHostStore.shared.rememberClaudePath(probe.claudePath, forHost: h.id)
                host = h
            }
        }

        // An Ollama on THIS Mac is not reachable from the remote machine, where
        // `localhost` means something else entirely. Forward the port instead of
        // letting the address silently resolve to whatever runs over there.
        var tunnelOptions: [String] = []
        if host != nil, model.provider != .anthropic,
           let tunnel = SSHClient.reverseTunnel(forServerURL: backend.url) {
            tunnelOptions = tunnel.options
        }

        let sid = sessionId ?? UUID().uuidString
        sessionId = sid
        let config = SessionConfig(
            claudePath: claudePath,
            workingDirectory: settings.workingDirectory,
            remoteHost: host,
            model: model,
            permissionMode: settings.permissionMode,
            effort: settings.effortLevel,
            appendSystemPrompt: composedSystemPrompt(),
            streamPartial: settings.streamPartialMessages,
            sessionId: sid,
            maxOutputTokens: settings.maxOutputTokensForChildEnv,
            maxConcurrentSubagents: settings.maxConcurrentSubagents,
            extraEnv: extraEnv,
            reverseTunnelOptions: tunnelOptions
        )
        do {
            // (This is where the old epoch was reset WITHOUT rewiring — which
            // silently discarded every event of every freshly started session.
            // With identity-based wiring there is nothing to reset.)
            let resumed = resumeOnNextStart
            AppLog.write("session", "start model=\(model.modelArg) provider=\(model.provider.rawValue) "
                         + "base=\(extraEnv["ANTHROPIC_BASE_URL"] ?? "anthropic") "
                         + "where=\(host.map { "ssh:" + $0.detailedTarget } ?? "local") "
                         + "tunnel=\(tunnelOptions.isEmpty ? "no" : "yes") "
                         + "effort=\(settings.effortLevel.cliValue) resume=\(resumed)")
            // Reasoning level travels in-band, not as a launch flag: applied
            // before the first turn, changeable any time via the effort button.
            let (effort, downgradedFrom) = await effectiveEffort()
            let preCommands = ["/effort \(effort.cliValue)"]
            pendingInternalResults += preCommands.count
            try session.start(config: config, firstContent: blocks,
                              resume: resumed, preCommands: preCommands)
            resumeOnNextStart = false
            if let from = downgradedFrom {
                appendNotice(.info, L10n.t("effort_adjusted", "\(from.cliValue) → \(effort.cliValue)"))
            }
            sessionBackendURL = backend.url
            // Routing is never hidden: when the turn fans out to other machines,
            // the transcript says which ones.
            if !backend.routedServers.isEmpty {
                appendNotice(.info, L10n.t("router_active",
                                           backend.routedServers.joined(separator: ", ")))
            }
            // One compact line in the transcript; the full copy-pastable command
            // lives in the notice's detail (tooltip + expandable).
            let serverHost = URL(string: conversationServerURL)?.host ?? "anthropic"
            let where_ = model.provider == .anthropic ? "Anthropic" : serverHost
            // Which machine the agent's tools act on is worth saying out loud:
            // "Bash" and "Edit" mean very different things on someone's server.
            let onMachine = host.map { " · ⇄ " + $0.label } ?? ""
            appendNotice(.info,
                         "$ claude --model \(model.modelArg) · \(where_)\(onMachine)"
                         + (resumed ? " · resume" : ""),
                         detail: launchCommandLine(config: config, resumed: resumed))
        } catch let failure as SSHClient.Failure {
            appendNotice(.error, L10n.t("ssh_launch_failed", host?.label ?? "")
                         + " — " + failure.message)
            statusLine = L10n.t("ssh_unreachable", host?.label ?? "")
            isRunning = false
        } catch {
            appendNotice(.error, L10n.t("launch_failed"))
            isRunning = false
        }
    }

    /// Decide the address `claude` should be pointed at for this turn.
    ///
    /// The default answer is the conversation's own server, unchanged and with
    /// nothing in the way — a conversation whose sub-agents all share its server
    /// pays no hop at all. `AgentRouter` is started only when a sub-agent's
    /// model carries an `@machine` suffix, because that is the only case a
    /// single `ANTHROPIC_BASE_URL` cannot express.
    private func resolveBackendURL(for model: LLMModel) async
        -> (url: String, routedServers: [String]) {
        guard model.provider != .anthropic else { return (conversationServerURL, []) }

        // Which machines this turn may need to reach beyond its own server:
        // the conversation's sub-agent setting first, plus any hand-written
        // `.claude/agents/*.md` that names one.
        var needed = Set<String>()
        let suffix = AgentDefinition.splitModelField(
            subagentModel.trimmingCharacters(in: .whitespaces)).serverName
        if !suffix.isEmpty { needed.insert(suffix) }
        await AgentStore.shared.loadIfNeeded(location: settings.workLocation)
        needed.formUnion(AgentStore.shared.referencedServerNames)
        guard !needed.isEmpty else { return (conversationServerURL, []) }

        let known = settings.standbyServers
        var byName: [String: String] = [:]
        for name in needed {
            if let server = known.first(where: { $0.name == name }) { byName[name] = server.url }
        }
        let missing = needed.subtracting(byName.keys).sorted()
        if !missing.isEmpty {
            appendNotice(.warning, L10n.t("agents_unknown_server",
                                          missing.joined(separator: ", ")))
        }
        // The router is also what makes "one sub-agent at a time" real. The CLI's
        // own cap does not queue — past its limit it fails the delegation and
        // tells the model not to retry — so serialising has to happen where a
        // request can be made to WAIT, which is here.
        let subagent = AgentDefinition.splitModelField(
            subagentModel.trimmingCharacters(in: .whitespaces)).model
        let mustSerialise = !subagent.isEmpty
            && subagent != model.modelArg
            && settings.maxConcurrentSubagents == 1
        guard !byName.isEmpty || mustSerialise else { return (conversationServerURL, []) }

        do {
            let base = try await AgentRouter.shared.start(route: .init(
                defaultUpstream: conversationServerURL,
                byServerName: byName,
                maxConcurrentPerServer: settings.maxConcurrentPerServer,
                subagentModel: subagent.isEmpty ? nil : subagent,
                maxConcurrentSubagents: settings.maxConcurrentSubagents))
            return (base, byName.keys.sorted())
        } catch {
            // Falling back to the conversation's server would send every routed
            // sub-agent to a machine that doesn't have its model. Say so, and
            // let the turn run with whatever still works.
            appendNotice(.error, L10n.t("router_failed", error.localizedDescription))
            return (conversationServerURL, [])
        }
    }

    /// The literal terminal command this session runs — same builders as the
    /// real spawn, so the display can never drift from what actually executes.
    private func launchCommandLine(config: SessionConfig, resumed: Bool) -> String {
        SessionConfig.displayCommand(config: config, resumed: resumed)
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
        // A sub-agent's internal events go to ITS activity feed, not the main
        // transcript.
        if let parent = env.parentToolUseId {
            handleAgentEvent(parent: parent, env)
            return
        }
        if ["assistant", "user", "result", "stream_event"].contains(env.type) {
            receivedContentThisTurn = true
            waitingHint = nil
            lastEventAt = Date()
        }
        // Any canonical event must see the streamed text already applied,
        // otherwise the final assistant message lands beside a half-written
        // duplicate instead of replacing it.
        if env.type != "stream_event" { flushStream() }
        switch env.type {
        case "system":
            // The CLI's background-task protocol: the only authoritative source
            // on which sub-agents are alive right now.
            if let s = env.subtype, s.hasPrefix("task_") {
                handleTaskEvent(env)
                return
            }
            if env.subtype == "init" {
                sessionId = env.sessionId ?? sessionId
                let model = env.model ?? selectedModel.name
                statusLine = "Session · \(model)"
                if let cmds = env.slashCommands, !cmds.isEmpty {
                    slashCommands = cmds.sorted()
                }
            }
        case "assistant":
            // Live token accounting: every assistant event carries this API
            // call's usage (verified). The gauge takes the latest footprint —
            // that IS the context, not a sum — while the running totals add each
            // call up, so both move mid-turn during long tool loops instead of
            // only at the end.
            if let u = env.message?.usage {
                let inHere = (u["input_tokens"]?.asInt ?? 0)
                    + (u["cache_read_input_tokens"]?.asInt ?? 0)
                    + (u["cache_creation_input_tokens"]?.asInt ?? 0)
                let outHere = u["output_tokens"]?.asInt ?? 0
                liveTurnInputTokens += inHere
                liveTurnOutputTokens += outHere
            }
            if let u = env.message?.usage {
                let footprint = (u["input_tokens"]?.asInt ?? 0)
                    + (u["cache_read_input_tokens"]?.asInt ?? 0)
                    + (u["cache_creation_input_tokens"]?.asInt ?? 0)
                    + (u["output_tokens"]?.asInt ?? 0)
                if footprint > 0 { contextTokens = footprint }
            }
            for block in env.message?.content ?? [] {
                switch block {
                // The /effort ack surfaces twice: as this assistant text AND as
                // the command's result (which becomes the notice). One is enough.
                case .text(let t) where t.hasPrefix("Set effort level"):
                    break
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
            // A malformed tool call from the model kills the whole turn: Ollama's
            // built-in parser answers HTTP 500 ("parse … call to X: missing …
            // wrapper") and everything the turn had left to do is lost. Measured
            // on muse-glimmer: three identical requests in a row parsed fine, so
            // the fault is an occasional bad sample, not an incompatibility —
            // exactly what a resend fixes, and what the CLI itself means by
            // "usually temporary". Bounded, so a real outage still surfaces.
            if shouldRetryTransient(env), let blocks = lastSentBlocks {
                transientRetries += 1
                appendNotice(.info, L10n.t("transient_retry", "\(transientRetries)/\(Self.maxTransientRetries)"),
                             detail: env.result)
                AppLog.write("session", "transient gateway failure — resending turn (\(transientRetries))")
                Task { await launchOrContinue(blocks) }
                return
            }
            // A reply that hit the ceiling looks terminal and isn't: the CLI
            // process is still alive and the conversation still holds. Saying so
            // is the whole point — this is the failure people answer by starting
            // a new conversation they never needed.
            if isOutputCapFailure(env) {
                appendNotice(.warning,
                             L10n.t("output_cap_hit", Self.formatTokens(settings.maxOutputTokens)),
                             detail: env.result)
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
                // The result is authoritative for the whole turn: settle with it
                // and drop the live running estimate rather than adding both.
                totalInputTokens += inTok + cacheRead + cacheCreate
                totalOutputTokens += outTok
                liveTurnInputTokens = 0
                liveTurnOutputTokens = 0
                // Feed the diagnostics dashboard with this turn's real figures.
                AppMetrics.shared.record(
                    modelId: selectedModel.id,
                    provider: selectedModel.provider.rawValue,
                    tokensIn: inTok + cacheRead + cacheCreate, tokensOut: outTok,
                    costUSD: env.totalCostUsd ?? 0,
                    latencyMs: env.durationMs ?? 0,
                    isError: env.isError ?? false
                )
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
                ModelWarmup.shared.start(model: m, server: server)
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
    ///
    /// Deltas are buffered, not applied one by one. Mutating `items` republishes
    /// the whole transcript and `currentReasoning` re-renders a panel that only
    /// grows; doing that per token means ~60 full SwiftUI passes a second on a
    /// local model, which is exactly the jerkiness and lag. Buffered and flushed
    /// at 20 Hz it reads as continuous and costs a fraction.
    private func handleStreamEvent(_ event: JSONValue?) {
        guard let event, event["type"]?.asString == "content_block_delta",
              let delta = event["delta"] else { return }
        switch delta["type"]?.asString {
        case "thinking_delta":
            if let t = delta["thinking"]?.asString, !t.isEmpty {
                pendingThinking += t
                streamedThinkingThisMessage = true
                scheduleStreamFlush()
            }
        case "text_delta":
            if let t = delta["text"]?.asString, !t.isEmpty {
                pendingText += t
                scheduleStreamFlush()
            }
        default:
            break
        }
    }

    // MARK: - Streaming coalescer

    private var pendingText = ""
    private var pendingThinking = ""
    private var streamFlushTask: Task<Void, Never>?
    private static let streamFlushInterval: UInt64 = 50_000_000   // 20 Hz

    private func scheduleStreamFlush() {
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.streamFlushInterval)
                guard let self else { return }
                self.flushStream()
                // Nothing buffered and the turn is over → stop ticking.
                if self.pendingText.isEmpty, self.pendingThinking.isEmpty, !self.isRunning {
                    self.streamFlushTask = nil
                    return
                }
            }
        }
    }

    /// Apply everything buffered. Must run before any canonical event is handled,
    /// so the final assistant message replaces exactly what was streamed.
    private func flushStream() {
        if !pendingThinking.isEmpty {
            currentReasoning += pendingThinking
            pendingThinking = ""
        }
        guard !pendingText.isEmpty else { return }
        let chunk = pendingText
        pendingText = ""
        if let idx = streamingTextIndex, idx < items.count,
           case .assistantText(let existing) = items[idx].kind {
            var copy = items[idx]
            copy.kind = .assistantText(existing + chunk)
            items[idx] = copy
        } else {
            appendItem(.assistantText(chunk))
            streamingTextIndex = items.count - 1
        }
    }

    /// Drop anything buffered — on stop, or when leaving the conversation.
    private func discardStreamBuffers() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        pendingText = ""
        pendingThinking = ""
    }

    private func handleStderr(_ s: String) {
        // Redact potential secrets before storing — avoid leaking API keys / tokens.
        let redacted = secretRedactor.redact(s)
        stderrTail = String((stderrTail + redacted).suffix(maxStderrTail))
        AppLog.write("claude", redacted)
    }

    /// Match actual Claude Code v2.x context-limit error messages.
    /// Gateway failures that mean "sample again", not "this cannot work".
    /// The CLI says so itself in the body: "usually temporary — try again".
    private static let transientGatewayPatterns = [
        "missing atem function_calls wrapper",
        "usually temporary",
        "server-side issue",
        "internal server error",
    ]
    /// How many times one turn may be resent before we let the failure stand.
    private static let maxTransientRetries = 2
    private var transientRetries = 0

    /// True when the turn died from a transient gateway fault and can be resent.
    private func shouldRetryTransient(_ env: StreamEnvelope) -> Bool {
        guard env.isError == true, transientRetries < Self.maxTransientRetries,
              let text = env.result?.lowercased() else { return false }
        // Never confuse it with a context overflow, which needs compaction.
        guard !Self.contextLimitPatterns.contains(where: { text.contains($0) }) else { return false }
        return Self.transientGatewayPatterns.contains { text.contains($0) }
    }

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

    /// 128000 → "128 000", so the notice names the same number the picker shows.
    static func formatTokens(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{202F}"
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// A turn that died because ONE REPLY was too long — not because the
    /// conversation is full.
    ///
    /// Worth keeping apart from `contextLimitPatterns`: compacting shortens the
    /// history, and the history is not what overflowed. Auto-compacting here
    /// would spend a turn to change nothing.
    private static let outputCapPatterns = [
        "output token maximum",
        "exceeded the maximum output",
        "max_tokens",
        "output_tokens exceeds",
    ]

    private func isOutputCapFailure(_ env: StreamEnvelope) -> Bool {
        guard env.isError == true, let text = env.result?.lowercased() else { return false }
        return Self.outputCapPatterns.contains { text.contains($0) }
    }

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
        guard canCompact else { return }
        statusLine = L10n.t("compacting")
        appendNotice(.info, L10n.t("compact_notice"))
        // Through the same launch path as a real turn, NOT `session.send`
        // directly: a conversation reopened from history has no process yet,
        // and `send` on an unstarted session drops the message on the floor —
        // which, with `isRunning` already set, left the app compacting forever
        // with no way back. This spawns or resumes as needed, and reports the
        // server being unreachable instead of hanging.
        Task { await launchOrContinue([["type": "text", "text": "/compact"]]) }
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
        // Modern token formats almost all contain '-', '_' or '.', which the
        // generic base64 rule below deliberately excludes (widening it would
        // swallow every long file path and make the log useless). So each shape
        // gets its own precise rule instead.
        for pat in [
            "sk-ant-[A-Za-z0-9_-]{20,}",            // Anthropic
            "sk-proj-[A-Za-z0-9_-]{20,}",           // OpenAI project keys
            "sk-[A-Za-z0-9]{20,}",                  // OpenAI classic
            "ghp_[A-Za-z0-9]{36}",                  // GitHub classic PAT
            "gh[opsu]_[A-Za-z0-9]{36,}",            // other GitHub tokens
            "github_pat_[A-Za-z0-9_]{20,}",         // GitHub fine-grained PAT
            "glpat-[A-Za-z0-9_-]{20,}",             // GitLab
            "xox[baprs]-[A-Za-z0-9-]{10,}",         // Slack
            "eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}",  // JWT
            "AKIA[0-9A-Z]{16}",                     // AWS access key id
            "[A-Za-z0-9+/]{40,}={0,2}",             // long unbroken base64 run
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
