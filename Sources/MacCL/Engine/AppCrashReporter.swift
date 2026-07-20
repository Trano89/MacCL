import Foundation

/// Collects crash-like diagnostics (uncaught exceptions, OS crash logs) and writes them to disk. */
@MainActor
final class AppCrashReporter: ObservableObject {
    static let shared = AppCrashReporter()

    /// An application-level crash report (Swift uncaught exception). */
    struct CrashReport: Identifiable, Codable {
        let id: UUID
        let date: Date
        let appVersion: String
        let appBuild: String
        let errorMessage: String
        let backtrace: String
        let platform: String
        let osVersion: String

        enum CodingKeys: String, CodingKey {
            case id, date, errorMessage, backtrace, platform, osVersion
            case appVersion, appBuild
        }
    }

    /// A macOS system-level crash entry (from DiagnosticReports). */
    struct SystemCrashEntry: Identifiable, Codable {
        let id: UUID
        let date: Date
        let processName: String
        let version: String?
        let exceptionCode: String
        let reportFilename: String
        let summaryLine: String

        init(id: UUID = .init(), date: Date, processName: String, version: String?,
             exceptionCode: String, reportFilename: String, summaryLine: String) {
            self.id = id
            self.date = date
            self.processName = processName
            self.version = version
            self.exceptionCode = exceptionCode
            self.reportFilename = reportFilename
            self.summaryLine = summaryLine
        }
    }

    /// Context snapshot captured alongside crash reports. */
    struct CrashContext: Codable {
        var modelId: String?
        var serverURL: String?
        var sessionRunning: Bool
        var turnCount: Int
        var bridgeEngine: String
        var uptimeSeconds: Double
        let date: Date
    }

    @Published private(set) var reports: [CrashReport] = []
    @Published private(set) var systemCrashes: [SystemCrashEntry] = []
    @Published private(set) var lastContext: CrashContext?

    private let reportsDir: URL
    private let systemCrashesDir: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("MacCL", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reportsDir = dir.appendingPathComponent("crashes")
        try? FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)

        // System crash logs live in ~/Library/Logs/DiagnosticReports
        let diagDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        systemCrashesDir = diagDir

        loadPendingReports()
        loadSystemCrashes()
        installHandlers()
    }

    private func installHandlers() {
        NSSetUncaughtExceptionHandler(AppCrashReporter.uncaughtExceptionHandler)
    }

    /// C-compatible uncaught exception handler — must not capture. */
    static let uncaughtExceptionHandler: @convention(c) (AnyObject) -> Void = { exception in
        let nsEx = exception as? NSException
        guard let name = nsEx?.name.rawValue, let reason = nsEx?.reason else { return }

        let msg = "\(name): \(reason)"
        let bt = Thread.callStackSymbols
        let report = CrashReport(
            id: UUID(), date: Date(),
            appVersion: AppCrashReporter.appVersion,
            appBuild: AppCrashReporter.appBuild,
            errorMessage: msg,
            backtrace: bt.joined(separator: "\n"),
            platform: "macOS",
            osVersion: AppCrashReporter.osVersion
        )
        AppCrashReporter.shared.save(report)

        let ctx = CrashContext(
            modelId: nil, serverURL: nil, sessionRunning: false, turnCount: 0,
            bridgeEngine: "", uptimeSeconds: ProcessInfo.processInfo.systemUptime, date: Date()
        )
        if let ctxData = try? JSONEncoder().encode(ctx) {
            // Persist context alongside crash report on disk. */
            _ = try? ctxData.write(to: AppCrashReporter.shared.reportsDir.appendingPathComponent("context-\(report.id).json"))
        }
    }

    // MARK: - System crash logs

    private func loadSystemCrashes() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: systemCrashesDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []

        for url in urls where url.pathExtension == "crash" {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let processName = plist["process"] as? String,
                  let exceptionType = plist["exception"] as? [String: Any],
                  let codes = exceptionType["codes"] as? [Int] else { continue }

            guard processName.contains("MacCL") || processName.contains("ClaudeMac") else { continue }

            let summary = codes.map { String($0) }.joined(separator: ", ")
            if let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) {
                let entry = SystemCrashEntry(
                    date: modDate, processName: processName, version: nil,
                    exceptionCode: summary, reportFilename: url.lastPathComponent,
                    summaryLine: "crash/\(processName)"
                )
                systemCrashes.append(entry)
            }
        }
    }

    // MARK: - App-level crash reports

    private func save(_ report: CrashReport) {
        let data = try? JSONEncoder().encode(report)
        let filename = "crash-\(ISO8601DateFormatter().string(from: report.date)).json"
        let url = reportsDir.appendingPathComponent(filename)
        try? data?.write(to: url)
        DispatchQueue.main.async { [reports] in self.reports = reports + [report] }
    }

    private func loadPendingReports() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: reportsDir, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let report = try? JSONDecoder().decode(CrashReport.self, from: data) else { continue }
            reports.append(report)
        }
    }

    /// Clear all crash reports (called from UI). */
    func clearReports() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: reportsDir, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" { try? FileManager.default.removeItem(at: url) }
        reports.removeAll()
    }

    // MARK: - Context capture

    /// Called from ChatViewModel before launching a new turn. */
    func recordTurnStart(modelId: String, serverURL: String, bridgeEngine: String) {
        let ctx = CrashContext(
            modelId: modelId, serverURL: serverURL,
            sessionRunning: true, turnCount: 0,
            bridgeEngine: bridgeEngine, uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            date: Date()
        )
        lastContext = ctx
    }

    func updateTurnProgress(increment: Int) {
        var ctx = lastContext ?? CrashContext(
            modelId: nil, serverURL: nil, sessionRunning: true, turnCount: 0,
            bridgeEngine: "", uptimeSeconds: ProcessInfo.processInfo.systemUptime, date: Date()
        )
        ctx.turnCount += increment
        lastContext = ctx
    }

    // MARK: - Device info (for crash reports)

    static var deviceInfo: [String: String] {
        var info: [String: String] = [:]
        info["os_version"] = Self.osVersion
        info["os_build"] = Self.osBuildNumber
        info["app_version"] = Self.appVersion
        info["app_build"] = Self.appBuild
        info["ram_gb"] = String(format: "%.1f", Self.totalMemoryGB)
        info["cpu_model"] = Self.cpuModel
        info["uptime_hours"] = String(format: "%.1f", ProcessInfo.processInfo.systemUptime / 3600)
        return info
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var osBuildNumber: String {
        ProcessInfo.processInfo.operatingSystemVersionString ?? "unknown"
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    private static var totalMemoryGB: Double {
        let mem = ProcessInfo.processInfo.physicalMemory
        return Double(mem) / (1024.0 * 1024.0 * 1024.0)
    }

    private static var cpuModel: String {
        #if arch(arm64)
        return "Apple Silicon"
        #elseif arch(x86_64)
        return "Intel"
        #else
        return "unknown"
        #endif
    }
}
