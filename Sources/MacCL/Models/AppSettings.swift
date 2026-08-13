import Foundation
import Combine
import SwiftUI

/// User-configurable settings, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var claudePathOverride: String {
        didSet { defaults.set(claudePathOverride, forKey: "claudePathOverride") }
    }
    @Published var workingDirectory: String {
        didSet { defaults.set(workingDirectory, forKey: "workingDirectory") }
    }
    /// Which machine `workingDirectory` belongs to: "" = this Mac, otherwise the
    /// id of an `SSHHost`. Kept beside the path rather than folded into it so a
    /// conversation saved before SSH existed still reads as local.
    @Published var workLocationHostId: String {
        didSet { defaults.set(workLocationHostId, forKey: "workLocationHostId") }
    }
    /// Saved SSH machines — JSON-encoded array of SSHHost (never any password).
    @Published var sshHostsRaw: String {
        didSet { defaults.set(sshHostsRaw, forKey: "sshHosts") }
    }
    @Published var selectedModelId: String {
        didSet { defaults.set(selectedModelId, forKey: "selectedModelId") }
    }
    @Published var permissionModeRaw: String {
        didSet { defaults.set(permissionModeRaw, forKey: "permissionModeRaw") }
    }
    @Published var effortLevelRaw: String {
        didSet { defaults.set(effortLevelRaw, forKey: "effortLevelRaw") }
    }
    /// Ollama server URL — must be http:// or https:// scheme.
    @Published var ollamaBaseURL: String {
        didSet {
            // Validate the NEW value, not oldValue. Persist only valid URLs.
            guard let validated = URLValidator.validate(ollamaBaseURL), !validated.isEmpty else { return }
            if validated != oldValue { defaults.set(validated, forKey: "ollamaBaseURL") }
        }
    }
    /// Cap on a single reply's output tokens (CLAUDE_CODE_MAX_OUTPUT_TOKENS).
    /// The CLI's own default is 32k; a long agentic turn hits it and dies mid-way
    /// ("response exceeded the … output token maximum"), so the app raises it —
    /// and now lets you raise it further.
    @Published var maxOutputTokens: Int {
        didSet { defaults.set(maxOutputTokens, forKey: "maxOutputTokens") }
    }
    /// Diagnostic verbosity of the log file (off … trace).
    @Published var logLevelRaw: String {
        didSet {
            defaults.set(logLevelRaw, forKey: "logLevel")
            AppLog.level = AppLog.Level(rawValue: logLevelRaw) ?? .warn
        }
    }
    /// Mirror diagnostics to stderr as well as the log file.
    @Published var diagnosticConsoleEnabled: Bool {
        didSet {
            defaults.set(diagnosticConsoleEnabled, forKey: "diagnosticConsoleEnabled")
            AppLog.consoleEnabled = diagnosticConsoleEnabled
        }
    }
    @Published var streamPartialMessages: Bool {
        didSet { defaults.set(streamPartialMessages, forKey: "streamPartialMessages") }
    }
    /// Show the model's reasoning in the transcript. Thinking itself follows
    /// `--effort` for every provider now — Ollama honours the Messages API's
    /// `thinking` field the same way Anthropic does.
    @Published var showReasoning: Bool {
        didSet { defaults.set(showReasoning, forKey: "showReasoning") }
    }
    /// UI language (defaults to the system language when supported).
    @Published var languageRaw: String {
        didSet { defaults.set(languageRaw, forKey: "languageRaw") }
    }
    /// Display theme appearance: "system" | "light" | "dark".
    @Published var appearanceThemeRaw: String {
        didSet { defaults.set(appearanceThemeRaw, forKey: "appearanceThemeRaw") }
    }
    /// Accent color as a hex RGB integer (e.g. 0xE37654 for coral).
    @Published var accentColorHex: Int {
        didSet { defaults.set(accentColorHex, forKey: "accentColorHex") }
    }
    /// Persisted standby Ollama servers — JSON-encoded array of StandbyServer.
    @Published var standbyServersRaw: String {
        didSet { defaults.set(standbyServersRaw, forKey: "standbyServers") }
    }
    /// Seed for a new conversation's sub-agent model (`model` or `model@machine`).
    /// Empty = sub-agents think with the conversation's own model.
    @Published var subagentModel: String {
        didSet { defaults.set(subagentModel, forKey: "subagentModel") }
    }
    /// How many sub-agents may run at once (CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS).
    ///
    /// The CLI's own default is 20, which is a number written for a cloud API,
    /// not for one Ollama box: twenty simultaneous turns against a single server
    /// queue behind each other and evict each other's models. 1 is strictly
    /// serial; the app defaults to 2 — one sub-agent alongside the main loop.
    @Published var maxConcurrentSubagents: Int {
        didSet { defaults.set(maxConcurrentSubagents, forKey: "maxConcurrentSubagents") }
    }
    /// Same cap, but applied per remote machine by `AgentRouter`. A second box
    /// is a second pool of RAM, so it gets its own allowance.
    @Published var maxConcurrentPerServer: Int {
        didSet { defaults.set(maxConcurrentPerServer, forKey: "maxConcurrentPerServer") }
    }

    private let defaults = UserDefaults.standard

    /// One-shot migration: the bundle id moved from com.antonin.maccl to
    /// com.trano89.maccl, and UserDefaults are keyed by bundle id — without
    /// this, every preference (theme, accent, servers, model…) would silently
    /// reset on first launch under the new identity.
    private static func migrateLegacyDefaultsIfNeeded(into defaults: UserDefaults) {
        guard defaults.object(forKey: "selectedModelId") == nil,
              let old = defaults.persistentDomain(forName: "com.antonin.maccl"),
              !old.isEmpty else { return }
        for (key, value) in old { defaults.set(value, forKey: key) }
    }

    private init() {
        Self.migrateLegacyDefaultsIfNeeded(into: defaults)
        claudePathOverride = defaults.string(forKey: "claudePathOverride") ?? ""
        workingDirectory = defaults.string(forKey: "workingDirectory")
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        workLocationHostId = defaults.string(forKey: "workLocationHostId") ?? ""
        sshHostsRaw = defaults.string(forKey: "sshHosts") ?? "[]"
        selectedModelId = defaults.string(forKey: "selectedModelId") ?? "anthropic:opus"
        permissionModeRaw = defaults.string(forKey: "permissionModeRaw")
            ?? PermissionMode.bypassPermissions.rawValue
        effortLevelRaw = defaults.string(forKey: "effortLevelRaw") ?? EffortLevel.high.rawValue
        ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        maxOutputTokens = defaults.integer(forKey: "maxOutputTokens") == 0
            ? 64_000 : max(8_000, min(512_000, defaults.integer(forKey: "maxOutputTokens")))
        logLevelRaw = defaults.string(forKey: "logLevel") ?? AppLog.Level.warn.rawValue
        diagnosticConsoleEnabled = defaults.bool(forKey: "diagnosticConsoleEnabled")
        streamPartialMessages = defaults.object(forKey: "streamPartialMessages") as? Bool ?? true
        showReasoning = defaults.object(forKey: "showReasoning") as? Bool ?? true
        languageRaw = defaults.string(forKey: "languageRaw") ?? AppLanguage.systemDefault.rawValue
        appearanceThemeRaw = defaults.string(forKey: "appearanceThemeRaw") ?? "system"
        accentColorHex = defaults.integer(forKey: "accentColorHex") == 0 ? 0xE37654 : defaults.integer(forKey: "accentColorHex")
        standbyServersRaw = defaults.string(forKey: "standbyServers") ?? "[]"
        subagentModel = defaults.string(forKey: "subagentModel") ?? ""
        // `integer(forKey:)` reads 0 for "never set" — treat that as the default
        // rather than as "zero sub-agents", which would be a cap of nothing.
        let storedConcurrency = defaults.integer(forKey: "maxConcurrentSubagents")
        maxConcurrentSubagents = storedConcurrency == 0 ? 2 : max(1, min(20, storedConcurrency))
        let storedPerServer = defaults.integer(forKey: "maxConcurrentPerServer")
        maxConcurrentPerServer = storedPerServer == 0 ? 2 : max(1, min(20, storedPerServer))
    }

    var language: AppLanguage {
        get { AppLanguage(rawValue: languageRaw) ?? .en }
        set { languageRaw = newValue.rawValue }
    }

    /// Where the current conversation's files live (this Mac, or an SSH host).
    var workLocation: WorkLocation {
        get { WorkLocation(hostId: workLocationHostId, path: workingDirectory) }
        set {
            workingDirectory = newValue.path
            workLocationHostId = newValue.hostId
        }
    }

    var permissionMode: PermissionMode {
        get { PermissionMode(rawValue: permissionModeRaw) ?? .bypassPermissions }
        set { permissionModeRaw = newValue.rawValue }
    }

    var logLevel: AppLog.Level {
        get { AppLog.Level(rawValue: logLevelRaw) ?? .warn }
        set { logLevelRaw = newValue.rawValue }
    }

    var effortLevel: EffortLevel {
        get { EffortLevel(rawValue: effortLevelRaw) ?? .high }
        set { effortLevelRaw = newValue.rawValue }
    }

    var appearanceTheme: String {
        get { appearanceThemeRaw == "" ? "system" : appearanceThemeRaw }
        set { appearanceThemeRaw = newValue }
    }

    /// Convert hex RGB int to SwiftUI Color.
    private static func colorFromHex(_ hex: Int) -> Color {
        let r = Double((hex & 0xFF0000) >> 16) / 255.0
        let g = Double((hex & 0x00FF00) >> 8) / 255.0
        let b = Double(hex & 0x0000FF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    var accentColor: Color { Self.colorFromHex(accentColorHex) }

    /// Decoded standby servers list.
    var standbyServers: [StandbyServer] {
        get { StandbyServer.decodeArray(from: standbyServersRaw) }
        set { standbyServersRaw = StandbyServer.encodeArray(newValue) }
    }

    /// Index of the currently-active standby server (if any).
    var currentStandbyIndex: Int? {
        standbyServers.firstIndex { $0.url == ollamaBaseURL }
    }

    /// Computed setter that activates a standby server as the Ollama URL.
    /// Returns an error string if the server is unreachable, nil on success.
    func activateStandby(at index: Int) async -> String? {
        guard index >= 0, index < standbyServers.count else { return "Serveur introuvable" }
        let server = standbyServers[index]
        // Check reachability before switching to avoid leaving the app in a broken state.
        guard await OllamaClient.isReachable(baseURL: server.url) else {
            return "Le serveur \(server.name) n'est pas joignable"
        }
        ollamaBaseURL = server.url
        return nil
    }

    /// Add a new standby server (deduped by URL).
    func addStandbyServer(_ server: StandbyServer) {
        var list = standbyServers
        list.removeAll { $0.url == server.url }
        list.append(server)
        standbyServers = list
    }

    /// Remove a standby server by ID.
    func removeStandbyServer(id: String) {
        standbyServers.removeAll { $0.id == id }
    }

}
