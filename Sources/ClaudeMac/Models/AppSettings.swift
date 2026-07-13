import Foundation
import Combine

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
    @Published var ollamaBaseURL: String {
        didSet { defaults.set(ollamaBaseURL, forKey: "ollamaBaseURL") }
    }
    /// Local Anthropic→Ollama router port.
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
        routerPort = defaults.integer(forKey: "routerPort") == 0 ? 8787 : defaults.integer(forKey: "routerPort")
        ollamaNumCtx = defaults.integer(forKey: "ollamaNumCtx") == 0 ? 16384 : defaults.integer(forKey: "ollamaNumCtx")
        ollamaMaxPredict = defaults.object(forKey: "ollamaMaxPredict") as? Int ?? 0
        streamPartialMessages = defaults.object(forKey: "streamPartialMessages") as? Bool ?? true
        showReasoning = defaults.object(forKey: "showReasoning") as? Bool ?? true
    }

    var permissionMode: PermissionMode {
        get { PermissionMode(rawValue: permissionModeRaw) ?? .bypassPermissions }
        set { permissionModeRaw = newValue.rawValue }
    }

    var effortLevel: EffortLevel {
        get { EffortLevel(rawValue: effortLevelRaw) ?? .high }
        set { effortLevelRaw = newValue.rawValue }
    }

    var routerBaseURL: String { "http://127.0.0.1:\(routerPort)" }
}
