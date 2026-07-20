import Foundation

/// A structured log event that can be surfaced in the UI (log tail viewer). */
struct LogEvent: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let source: String
    /// The severity level (mirrors AppLog.Level).
    let severity: Int              // rawValue of AppLog.Level
    let severityLabel: String      // ERR / WRN / INF / DBG / TRC
    let message: String
    /// Machine-readable error code (e.g. "NET_TIMEOUT", "AUTH_INVALID").
    let errorCode: String?

    init(source: String, severity: Int, severityLabel: String, message: String, errorCode: String? = nil) {
        self.id = UUID()
        self.date = Date()
        self.source = source
        self.severity = severity
        self.severityLabel = severityLabel
        self.message = message
        self.errorCode = errorCode
    }

    var timestamp: String {
        Self._formatter.dateFormat = "HH:mm:ss.SSS"
        return Self._formatter.string(from: date)
    }

    @MainActor
    static private let _formatter = DateFormatter()
}

/// Configurable diagnostic logger for MacCL.
enum AppLog {

    /// Severity levels — higher rawValue = more verbose. default off=0, error=1, warn=2, info=3, debug=4, trace=5. */
    enum Level: String, CaseIterable, Sendable {
        case off = "off"
        case error = "error"
        case warn  = "warn"
        case info  = "info"
        case debug = "debug"
        case trace = "trace"

        var levelInt: Int {
            switch self {
            case .off:     return 0
            case .error:   return 1
            case .warn:    return 2
            case .info:    return 3
            case .debug:   return 4
            case .trace:   return 5
            }
        }

        var shortLabel: String {
            switch self {
            case .off:     return "OFF"
            case .error:   return "ERR"
            case .warn:    return "WRN"
            case .info:    return "INF"
            case .debug:   return "DBG"
            case .trace:   return "TRC"
            }
        }

        var systemImage: String {
            switch self {
            case .off:     return "circle.fill"
            case .error:   return "exclamationmark.triangle.fill"
            case .warn:    return "exclamationmark.circle.fill"
            case .info:    return "info.circle.fill"
            case .debug:   return "magnifyingglass.fill"
            case .trace:   return "waveform.path.ecg.fill"
            }
        }

        var colorName: String {
            switch self {
            case .off:     return "gray"
            case .error:   return "red"
            case .warn:    return "orange"
            case .info:    return "blue"
            case .debug:   return "green"
            case .trace:   return "purple"
            }
        }

        init?(rawLevelInt: Int) {
            switch rawLevelInt {
            case 0: self = .off
            case 1: self = .error
            case 2: self = .warn
            case 3: self = .info
            case 4: self = .debug
            case 5: self = .trace
            default: return nil
            }
        }
    }

    static var level: Level = .warn {
        didSet { 
            if #unavailable(macOS 13.0) { return }
            DispatchQueue.main.async { [self] in
                Self.logLevelDisplayName = level.rawValue.capitalized
            }
        }
    }

    /// UI-visible display name for the current log level.
    @MainActor static var logLevelDisplayName: String = AppLog.level.rawValue.capitalized

    /// When true, logs are also written to stderr so they appear in the Xcode console. */
    static var consoleEnabled: Bool = false

    // MARK: - Log tail (in-memory ring buffer, last N events)

    @MainActor static var logTail: [LogEvent] = []
    private static let maxTailEntries = 5000
    private static let maxTailDisplayed = 2000   // cap UI rendering at 2k events

    /// Minimum severity shown in the tail viewer (nil = show all).
    @MainActor static var logTailMinSeverity: Int? {
        didSet { _updateTailFilterCount() }
    }

    @MainActor private(set) static var logTailFilteredCount = 0

    /// Whether the log tail viewer should auto-scroll to the latest entry. */
    @MainActor static var logTailAutoScroll: Bool = false

    // MARK: - Error categorization helpers

    enum ErrorCategory: String, Sendable {
        case networkTimeout   = "NET_TIMEOUT"
        case networkRefused   = "NET_REFUSED"
        case networkDNS       = "NET_DNS"
        case authInvalid      = "AUTH_INVALID"
        case quotaExceeded    = "QUOTA_EXCEEDED"
        case contextLimit     = "CONTEXT_LIMIT"
        case modelNotFound    = "MODEL_NOT_FOUND"
        case bridgeCrash      = "BRIDGE_CRASH"
        case sessionExpired   = "SESSION_EXPIRED"
        case fileRead         = "FILE_READ"
        case fileWrite        = "FILE_WRITE"
        case invalidConfig    = "INVALID_CONFIG"
        case unknown          = "UNKNOWN"

        static func from(message: String, code: String?) -> ErrorCategory {
            if let code, let cat = ErrorCategory(rawValue: code) { return cat }
            let lower = message.lowercased()
            if lower.contains("timed out") || lower.contains("timeout") { return .networkTimeout }
            if lower.contains("refused") || lower.contains("connection failed") { return .networkRefused }
            if lower.contains("dns") || lower.contains("could not resolve") { return .networkDNS }
            if lower.contains("unauthorized") || lower.contains("401") || lower.contains("invalid api key") { return .authInvalid }
            if lower.contains("quota") || lower.contains("rate limit") || lower.contains("429") { return .quotaExceeded }
            if lower.contains("context") && (lower.contains("limit") || lower.contains("size") || lower.contains("exceed")) { return .contextLimit }
            if lower.contains("model not found") || lower.contains("no such model") { return .modelNotFound }
            if lower.contains("crash") || lower.contains("terminated") { return .bridgeCrash }
            if lower.contains("expired") || lower.contains("session ended") { return .sessionExpired }
            if lower.contains("read") || lower.contains("open file") { return .fileRead }
            if lower.contains("write") || lower.contains("permission denied") { return .fileWrite }
            if lower.contains("invalid") || lower.contains("misconfigur") { return .invalidConfig }
            return .unknown
        }
    }

    /// Grouped error counts by category — computed from the tail. */
    @MainActor static var errorCategoryCounts: [ErrorCategory: Int] {
        let errors = logTail.filter { $0.severity >= Level.error.levelInt }
        var counts: [ErrorCategory: Int] = [:]
        for evt in errors {
            let cat = ErrorCategory.from(message: evt.message, code: evt.errorCode)
            counts[cat, default: 0] += 1
        }
        // Only return categories that have at least 1 count, sorted by count desc. */
        return counts.filter { $0.value > 0 }.sorted { $0.value > $1.value }.reduce(into: [:]) {
            $0[$1.key] = $1.value
        }
    }

    // MARK: - Deduplication (suppress repeated identical messages)

    private struct DedupEntry { let count: Int; let firstSeen: Date }
    private static var dedupMap: [String: DedupEntry] = [:]
    private static let dedupWindow: TimeInterval = 30   // same message within 30s merges into one

    // MARK: - File log (append-only, ~/Library/Logs/MacCL/maccl.log)

    private static let queue = DispatchQueue(label: "maccl.applog")
    private static let maxBytes = 4 * 1024 * 1024

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MacCL", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("maccl.log")
    }

    // MARK: - Public API

    /// Low-level write — always honored (bypasses log level). Useful for crash dumps. */
    static func write(_ source: String, _ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] [\(source)] \(text)\n"
            guard let data = line.data(using: .utf8) else { return }
            let url = fileURL
            rotateIfNeeded(url)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
        if #unavailable(macOS 13.0) { return }
        DispatchQueue.main.async { Self.addTailEntry(source: source, level: .debug, message: text) }
    }

    /// Write a structured log event with an optional error code.
    static func log(_ source: String, _ message: String, severity: Level = .info,
                    errorCode: String? = nil) {
        let dedupKey = "\(source)|\(severity.rawValue)|\(message.prefix(80))"

        // Dedup check (thread-safe). */
        var shouldEmit = true
        var dupCount = 1
        queue.sync {
            let now = Date()
            if let existing = dedupMap[dedupKey], (now.timeIntervalSince(existing.firstSeen)) < dedupWindow {
                dupCount = existing.count + 1
                dedupMap[dedupKey] = DedupEntry(count: dupCount, firstSeen: existing.firstSeen)
                // Emit on first 2 occurrences, then at 5, 10, and every 50th. */
                shouldEmit = (dupCount == 5 || dupCount == 10 || dupCount % 50 == 0) || dupCount <= 2
            } else {
                dedupMap[dedupKey] = DedupEntry(count: 1, firstSeen: now)
            }
        }

        // Auto-escalate: repeated same-source messages bump severity after threshold. */
        var actualSeverity = severity
        if case .warn = severity, dupCount >= 5 { actualSeverity = .error }
        else if case .info = severity, dupCount >= 10 { actualSeverity = .warn }

        guard level.levelInt >= actualSeverity.levelInt || shouldEmit else { return }

        let tailMsg = (dupCount > 1) ? "\(message) (x\(dupCount))" : message
        if #unavailable(macOS 13.0) { return }
        DispatchQueue.main.async { Self.addTailEntry(source: source, level: actualSeverity, message: tailMsg, errorCode: errorCode) }

        queue.async { [sevLabel = actualSeverity.shortLabel, ec = errorCode, dup = dupCount] in
            let stamp = ISO8601DateFormatter().string(from: Date())
            let codeStr = (ec != nil) ? " [\((ec!))]" : ""
            let dupStr = (dup > 1) ? " [x\(dup)]" : ""
            let line = "[\(stamp)] [\(sevLabel)\(codeStr)] \(source) \(tailMsg)\(dupStr)\n"
            guard let data = line.data(using: .utf8) else { return }

            // File log
            let url = fileURL
            rotateIfNeeded(url)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }

            // Console (stderr)
            if consoleEnabled { fputs(line, stderr) }
        }
    }

    /// Convenience methods gated by the current log level. */
    static func error(_ source: String, _ message: String, errorCode: String? = nil) {
        guard level.levelInt >= Level.error.levelInt else { return }
        log(source, message, severity: .error, errorCode: errorCode)
    }

    static func warn(_ source: String, _ message: String, errorCode: String? = nil) {
        guard level.levelInt >= Level.warn.levelInt else { return }
        log(source, message, severity: .warn, errorCode: errorCode)
    }

    /// info is useful for diagnosing router bridge state, server changes, etc. */
    static func info(_ source: String, _ message: String) {
        guard level.levelInt >= Level.info.levelInt else { return }
        log(source, message, severity: .info)
    }

    /// debug captures per-turn metrics, token counts, stream events — set logLevel to .debug for full telemetry. */
    static func debug(_ source: String, _ message: String) {
        guard level.levelInt >= Level.debug.levelInt else { return }
        log(source, message, severity: .debug)
    }

    /// trace captures ultra-low-level detail (per-chunk HTTP bytes, JSON decode trees). Use sparingly. */
    static func trace(_ source: String, _ message: String) {
        guard level.levelInt >= Level.trace.levelInt else { return }
        log(source, message, severity: .trace)
    }

    // MARK: - UI helpers

    /// Count of errors in the tail (for dashboard badge). */
    @MainActor static var errorCountInTail: Int {
        logTail.filter { $0.severity >= Level.error.levelInt }.count
    }

    /// Count of warnings in the tail. */
    @MainActor static var warningCountInTail: Int {
        logTail.filter { $0.severity >= Level.warn.levelInt && $0.severity < Level.error.levelInt }.count
    }

    /// Clear the log tail (called from UI). */
    @MainActor static func clearLogTail() {
        logTail.removeAll(keepingCapacity: true)
        logTailFilteredCount = 0
        _updateTailFilterCount()
    }

    // MARK: - Internal helpers

    @MainActor private static func _updateTailFilterCount() {
        guard let minSev = logTailMinSeverity else {
            logTailFilteredCount = logTail.count
            return
        }
        logTailFilteredCount = logTail.filter { $0.severity >= minSev }.count
    }

    /// Add to the in-memory ring buffer (MainActor). */
    @MainActor
    private static func addTailEntry(source: String, level: Level, message: String, errorCode: String? = nil) {
        let event = LogEvent(
            source: source,
            severity: level.levelInt,
            severityLabel: level.shortLabel,
            message: message,
            errorCode: errorCode
        )
        logTail.append(event)
        if logTail.count > maxTailEntries {
            logTail.removeFirst(logTail.count - maxTailDisplayed)
        }
        _updateTailFilterCount()
    }

    /// Keep one previous generation so the log can't grow without bound. */
    private static func rotateIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes else { return }
        let old = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
