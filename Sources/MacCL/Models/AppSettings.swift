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
    /// Local Anthropic→Ollama router port.
    /// Which bridge translates Claude Code's Anthropic API into Ollama calls.
    @Published var bridgeEngineRaw: String {
        didSet { defaults.set(bridgeEngineRaw, forKey: "bridgeEngineRaw") }
    }
    /// Port for the LiteLLM proxy (kept separate from the built-in router's).
    @Published var litellmPort: Int {
        didSet { defaults.set(litellmPort, forKey: "litellmPort") }
    }
    @Published var routerPort: Int {
        didSet { defaults.set(routerPort, forKey: "routerPort") }
    }
    /// Context window (num_ctx) for local models. Bounds the KV-cache RAM.
    @Published var ollamaNumCtx: Int {
        didSet { defaults.set(ollamaNumCtx, forKey: "ollamaNumCtx") }
    }
    /// Max output tokens (num_predict) for local models. 0 = follow Claude Code,
    /// -1 = unlimited (generate until stop / context full).
    @Published var ollamaMaxPredict: Int {
        didSet { defaults.set(ollamaMaxPredict, forKey: "ollamaMaxPredict") }
    }
    @Published var streamPartialMessages: Bool {
        didSet { defaults.set(streamPartialMessages, forKey: "streamPartialMessages") }
    }
    /// Show the model's reasoning. For local models this enables Ollama thinking
    /// via the router (`--think`); for Anthropic models thinking follows --effort.
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
    /// Logging severity (off / error / warn / info / debug). default = .warn.
    @Published var logLevelRaw: String {
        didSet {
            defaults.set(logLevelRaw, forKey: "logLevel")
            AppLog.level = AppLog.Level(rawValue: logLevelRaw) ?? .warn
        }
    }
    /// Whether diagnostic logs are also emitted to stderr (Xcode console).
    @Published var diagnosticConsoleEnabled: Bool {
        didSet {
            defaults.set(diagnosticConsoleEnabled, forKey: "diagnosticConsoleEnabled")
            AppLog.consoleEnabled = diagnosticConsoleEnabled
        }
    }

    /// Computed log level from the persisted raw string. */
    var logLevel: AppLog.Level {
        get { AppLog.Level(rawValue: logLevelRaw) ?? .warn }
        set { logLevelRaw = newValue.rawValue }
    }
    /// Whether the workspace panel should be shown by default.
    @Published var showWorkspaceRaw: Bool {
        didSet { defaults.set(showWorkspaceRaw, forKey: "showWorkspace") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        claudePathOverride = defaults.string(forKey: "claudePathOverride") ?? ""
        workingDirectory = defaults.string(forKey: "workingDirectory")
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        selectedModelId = defaults.string(forKey: "selectedModelId") ?? "anthropic:opus"
        permissionModeRaw = defaults.string(forKey: "permissionModeRaw")
            ?? PermissionMode.bypassPermissions.rawValue
        effortLevelRaw = defaults.string(forKey: "effortLevelRaw") ?? EffortLevel.high.rawValue
        ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        routerPort = defaults.integer(forKey: "routerPort") == 0 ? 8787 : max(1024, min(65535, defaults.integer(forKey: "routerPort")))
        bridgeEngineRaw = defaults.string(forKey: "bridgeEngineRaw") ?? BridgeEngine.builtin.rawValue
        litellmPort = defaults.integer(forKey: "litellmPort") == 0 ? 4000 : max(1024, min(65535, defaults.integer(forKey: "litellmPort")))
        ollamaNumCtx = defaults.integer(forKey: "ollamaNumCtx") == 0 ? 16384 : defaults.integer(forKey: "ollamaNumCtx")
        ollamaMaxPredict = defaults.object(forKey: "ollamaMaxPredict") as? Int ?? 0
        streamPartialMessages = defaults.object(forKey: "streamPartialMessages") as? Bool ?? true
        showReasoning = defaults.object(forKey: "showReasoning") as? Bool ?? true
        languageRaw = defaults.string(forKey: "languageRaw") ?? AppLanguage.systemDefault.rawValue
        appearanceThemeRaw = defaults.string(forKey: "appearanceThemeRaw") ?? "system"
        accentColorHex = defaults.integer(forKey: "accentColorHex") == 0 ? 0xE37654 : defaults.integer(forKey: "accentColorHex")
        standbyServersRaw = defaults.string(forKey: "standbyServers") ?? "[]"
        showWorkspaceRaw = defaults.object(forKey: "showWorkspace") as? Bool ?? false
        logLevelRaw = defaults.string(forKey: "logLevel") ?? AppLog.Level.warn.rawValue
        diagnosticConsoleEnabled = defaults.bool(forKey: "diagnosticConsoleEnabled")
    }

    var language: AppLanguage {
        get { AppLanguage(rawValue: languageRaw) ?? .en }
        set { languageRaw = newValue.rawValue }
    }

    var permissionMode: PermissionMode {
        get { PermissionMode(rawValue: permissionModeRaw) ?? .bypassPermissions }
        set { permissionModeRaw = newValue.rawValue }
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

    var routerBaseURL: String { "http://127.0.0.1:\(routerPort)" }
    var litellmBaseURL: String { "http://127.0.0.1:\(litellmPort)" }

    var bridgeEngine: BridgeEngine {
        get { BridgeEngine(rawValue: bridgeEngineRaw) ?? .builtin }
        set { bridgeEngineRaw = newValue.rawValue }
    }
}
