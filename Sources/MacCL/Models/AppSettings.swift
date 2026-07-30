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
    /// ("response exceeded the … output token maximum"), so the app raises it.
    /// The value is written to the CLI's own settings file, which makes it the
    /// official preference — it applies to `claude` in a terminal too.
    @Published var maxOutputTokens: Int {
        didSet {
            defaults.set(maxOutputTokens, forKey: "maxOutputTokens")
            syncMaxOutputToCLI()
        }
    }

    /// Why the last write to the CLI's settings file failed, if it did.
    @Published private(set) var cliConfigError: String?

    /// Push the cap into `~/.claude/settings.json`. Sole source of that key:
    /// `ClaudeSession` deliberately does not also put it in the child's
    /// environment (two sources make the CLI fall back to its default).
    func syncMaxOutputToCLI() {
        cliConfigError = ClaudeCLIConfig.setEnv(
            ["CLAUDE_CODE_MAX_OUTPUT_TOKENS": String(maxOutputTokens)])
    }

    /// What to inject into the child's environment: nothing when the settings
    /// file holds the value, the cap itself only as a fallback if that write
    /// failed — better a duplicated source than silently dropping to 32k.
    var maxOutputTokensForChildEnv: Int {
        cliConfigError == nil ? 0 : maxOutputTokens
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
        selectedModelId = defaults.string(forKey: "selectedModelId") ?? "anthropic:opus"
        permissionModeRaw = defaults.string(forKey: "permissionModeRaw")
            ?? PermissionMode.bypassPermissions.rawValue
        effortLevelRaw = defaults.string(forKey: "effortLevelRaw") ?? EffortLevel.high.rawValue
        ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        // Clamped to what the CLI will actually honour — a stored 512 000 from an
        // earlier build would otherwise keep promising four times the real cap.
        maxOutputTokens = defaults.integer(forKey: "maxOutputTokens") == 0
            ? 64_000
            : max(8_000, min(ClaudeCLIConfig.maxOutputCeiling, defaults.integer(forKey: "maxOutputTokens")))
        logLevelRaw = defaults.string(forKey: "logLevel") ?? AppLog.Level.warn.rawValue
        diagnosticConsoleEnabled = defaults.bool(forKey: "diagnosticConsoleEnabled")
        streamPartialMessages = defaults.object(forKey: "streamPartialMessages") as? Bool ?? true
        showReasoning = defaults.object(forKey: "showReasoning") as? Bool ?? true
        languageRaw = defaults.string(forKey: "languageRaw") ?? AppLanguage.systemDefault.rawValue
        appearanceThemeRaw = defaults.string(forKey: "appearanceThemeRaw") ?? "system"
        accentColorHex = defaults.integer(forKey: "accentColorHex") == 0 ? 0xE37654 : defaults.integer(forKey: "accentColorHex")
        standbyServersRaw = defaults.string(forKey: "standbyServers") ?? "[]"
        // didSet doesn't fire during init, so publish the cap once at startup —
        // this is also what repairs a settings.json left with an old value.
        syncMaxOutputToCLI()
    }

    var language: AppLanguage {
        get { AppLanguage(rawValue: languageRaw) ?? .en }
        set { languageRaw = newValue.rawValue }
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
