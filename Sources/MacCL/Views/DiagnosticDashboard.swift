import SwiftUI

// MARK: - Main Dashboard

/// Diagnostic dashboard — cost, tokens, latency, errors, log level, crash reports. */
struct DiagnosticDashboardView: View {
    @EnvironmentObject var settings: AppSettings

    @ObservedObject private var metrics = AppMetrics.shared
    @ObservedObject private var crashes = AppCrashReporter.shared
    @State private var showingResetAlert = false
    @State private var logLevelIndex: Int = 0
    @State private var searchQuery = ""
    @State private var minSeverity: Int? = nil

    private let severityLevels = AppLog.Level.allCases.filter { $0 != .off }
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        Form {
            // ---- Health Status ----
            Section("Statut") { healthRow }

            // ---- Log Level ----
            Section("Journalisation") { logLevelSection }

            // ---- Summary tiles ----
            Section("Résumé") { summarySection }

            // ---- Latency percentiles ----
            if !metrics.recentMetrics.isEmpty { latencySection }

            // ---- Per-model breakdown ----
            if !metrics.summary.perModelBreakdown.isEmpty {
                Section("Par modèle") { perModelSection }
            }

            // ---- Daily trend ----
            if !metrics.summary.dailyTrend.isEmpty {
                Section("Coût quotidien (\(metrics.summary.dailyTrend.count) jours)") { dailyTrendSection }
            }

            // ---- Slow turns ----
            if !metrics.summary.slowTurns.isEmpty {
                Section("Requêtes lentes (>\(Int(AppMetrics.slowTurnThresholdMs / 1000))s)") { slowTurnsSection }
            }

            // ---- Recent turns ----
            if !metrics.recentMetrics.isEmpty {
                Section("Derniers tours (\(metrics.recentMetrics.count))") { recentTurnsSection }
            }

            // ---- Error categories ----
            if !AppLog.errorCategoryCounts.isEmpty {
                Section("Erreurs par catégorie") { errorCategorySection }
            }

            // ---- Log Tail ----
            logTailSection

            // ---- Crash reports ----
            crashReportsSection

            // ---- Actions ----
            actionsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
    }

    // MARK: - Health Row

    private var healthRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                healthBadge(icon: "router", label: "Routeur", healthy: metrics.recentMetrics.isEmpty ? nil : !metrics.summary.errorRate.isNaN, color: .blue)
                healthBadge(icon: "server.rack", label: "Ollama", healthy: nil, color: .green)
                healthBadge(icon: "cpu", label: "Claude", healthy: metrics.recentMetrics.isEmpty ? nil : metrics.recentMetrics.last?.isError == false, color: .purple)
            }

            if let last = metrics.recentMetrics.last {
                Text("Dernier tour: \(last.modelId) · \(Int(last.latencyMs))ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Aucun tour enregistré")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func healthBadge(icon: String, label: String, healthy: Bool?, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
            Circle()
                .fill(healthy == nil ? .gray : (healthy! ? color : .red))
                .frame(width: 8, height: 8)
        }
    }

    // MARK: - Log Level Section

    private var logLevelSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("Niveau de log", selection: $logLevelIndex) {
                    ForEach(0..<AppLog.Level.allCases.count, id: \.self) { idx in
                        Text(AppLog.Level.allCases[idx].rawValue.capitalized).tag(idx)
                    }
                }
                .onChange(of: logLevelIndex) { _, newVal in
                    settings.logLevelRaw = AppLog.Level.allCases[newVal].rawValue
                }

                Spacer()

                // Quick filter
                Picker("Filtre", selection: Binding(
                    get: { minSeverity ?? 0 },
                    set: { minSeverity = $0 > 0 ? $0 : nil }
                )) {
                    Text("Tout").tag(0)
                    ForEach(severityLevels.indices, id: \.self) { idx in
                        let level = severityLevels[idx]
                        Text("\(level.shortLabel)")
                            .tag(level.levelInt)
                    }
                }
                .frame(width: 70)
            }

            Toggle("Afficher dans la console Xcode", isOn: $settings.diagnosticConsoleEnabled)

            HStack {
                Text("Total: \(AppLog.logTail.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let count = AppLog.logTailMinSeverity {
                    Text("Filtre: \(count)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Coût total") {
                HStack(spacing: 4) {
                    Image(systemName: "dollarsign.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatCost(metrics.totalCostUSD))
                        .fontWeight(.semibold)
                        .font(.system(.body, design: .monospaced))
                }
            }

            LabeledContent("Tours") {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(metrics.summary.turnCount)")
                        .fontWeight(.semibold)
                        .font(.system(.body, design: .monospaced))
                }
            }

            LabeledContent("Total tokens") {
                HStack(spacing: 4) {
                    Image(systemName: "text.page")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(metrics.summary.totalTokens.formatted())")
                        .fontWeight(.semibold)
                        .font(.system(.body, design: .monospaced))
                }
            }

            LabeledContent("Erreurs") {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(metrics.summary.errorRate > 0 ? .red : .green)
                    Text("\(metrics.summary.errorCount) (\(String(format: "%.1f", metrics.summary.errorRate * 100))%)")
                        .fontWeight(.semibold)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
    }

    // MARK: - Latency Section

    private var latencySection: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "clock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Latence").fontWeight(.medium)
                Spacer()
            }

            let s = metrics.summary
            LabeledContent("Moyenne", value: "\(Int(s.avgLatencyMs)) ms")
            LabeledContent("Mediane (p50)", value: "\(s.medianLatencyMs) ms")
            LabeledContent("95e percentile", value: "\(s.p95LatencyMs) ms")
            LabeledContent("99e percentile", value: "\(s.p99LatencyMs) ms")
            HStack {
                Text("Min / Max").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(s.minLatencyMs) ms / \(s.maxLatencyMs) ms").font(.system(.caption2, design: .monospaced))
            }

            // Mini latency bar chart (last 20 turns)
            if !metrics.recentMetrics.isEmpty {
                latencyBarChart
                    .frame(height: 60)
                    .padding(.top, 4)
            }
        }
    }

    private var latencyBarChart: some View {
        let maxLat = metrics.recentMetrics.suffix(20).map(\.latencyMs).max() ?? 1
        return GeometryReader { geo in
            let barWidth = max(4, (geo.size.width - 16) / 20 - 2)
            HStack(spacing: 2) {
                ForEach(Array(metrics.recentMetrics.suffix(20).enumerated()), id: \.offset) { _, m in
                    Rectangle()
                        .fill(latencyColor(m.latencyMs, maxLat: maxLat))
                        .frame(width: barWidth, height: max(2, Double(m.latencyMs) / Double(maxLat) * 50))
                        .cornerRadius(2)
                }
            }
        }
    }

    private func latencyColor(_ ms: Int, maxLat: Int) -> Color {
        let ratio = Double(ms) / Double(maxLat)
        if ratio > 0.9 { return .red }
        if ratio > 0.6 { return .orange }
        if ratio > 0.3 { return .yellow }
        return .green
    }

    // MARK: - Per-model Section

    private var perModelSection: some View {
        ForEach(metrics.summary.perModelBreakdown.indices) { i in
        let entry = metrics.summary.perModelBreakdown[i]
            LabeledContent(entry.modelId) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Tours: \(entry.turns)").font(.caption2).foregroundStyle(.secondary)
                        Text("Coût: \(formatCost(entry.costUSD))").font(.caption2).foregroundStyle(.secondary)
                    }
                    let errorColor = entry.errorRate > 0.1 ? Color.red : (entry.errorRate > 0 ? Color.orange : Color.green)
                    HStack(spacing: 8) {
                        Text("Latence moy: \(Int(entry.avgLatencyMs))ms").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(errorColor)
                        Text("\(String(format: "%.0f", entry.errorRate * 100))%").font(.system(.caption2, design: .monospaced)).foregroundStyle(errorColor)
                    }
                }
            }
        }
    }

    // MARK: - Daily Trend Section

    private var dailyTrendSection: some View {
        VStack(spacing: 8) {
            // Mini cost chart
            if !metrics.summary.dailyTrend.isEmpty {
                let maxCost = metrics.summary.dailyTrend.map(\.costUSD).max() ?? 1
                GeometryReader { geo in
                    let barWidth = max(3, (geo.size.width - 8) / Double(metrics.summary.dailyTrend.count) - 1)
                    HStack(spacing: 1) {
                        ForEach(Array(metrics.summary.dailyTrend.enumerated()), id: \.offset) { _, d in
                            let h = maxCost > 0 ? min(50, (d.costUSD / maxCost) * 50) : 2
                            Rectangle()
                                .fill(d.costUSD > 0 ? Color.blue.opacity(0.7) : Color.gray.opacity(0.3))
                                .frame(width: barWidth, height: h)
                                .cornerRadius(1)
                        }
                    }
                }
                .frame(height: 60)
            }

            ForEach(metrics.summary.dailyTrend.reversed(), id: \.day) { day in
                HStack {
                    Text(day.day.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(day.turns) tours")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(formatCost(day.costUSD))
                        .font(.system(.caption2, design: .monospaced))
                    if day.errorCount > 0 {
                        Text("\(day.errorCount) err")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Slow Turns Section

    private var slowTurnsSection: some View {
        ForEach(metrics.summary.slowTurns.indices, id: \.self) { i in
            let t = metrics.summary.slowTurns[i]
            HStack(spacing: 6) {
                Image(systemName: "clock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.modelId).font(.system(.caption2, design: .monospaced))
                    Text("\(t.latencyMs)ms").font(.system(.caption2, design: .monospaced)).foregroundStyle(.orange)
                }
                Spacer()
                Text(t.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Recent Turns Section

    private var recentTurnsSection: some View {
        ForEach(metrics.recentMetrics.suffix(20).reversed()) { metric in
            turnRow(metric)
        }
    }

    // MARK: - Error Category Section

    private var errorCategorySection: some View {
        let counts = AppLog.errorCategoryCounts
        return Group {
            if counts.isEmpty {
                EmptyView()
            } else {
                ForEach(Array(counts.keys), id: \.rawValue) { cat in
                    HStack(spacing: 6) {
                        Text(cat.rawValue).font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(counts[cat] ?? 0)")
                            .fontWeight(.medium)
                            .font(.system(.caption2, design: .monospaced))
                    }
                }
            }
        }
    }

    // MARK: - Log Tail Section

    private var logTailSection: some View {
        Section("Journal en direct (\(AppLog.logTailFilteredCount.formatted()))") {
            VStack(spacing: 4) {
                if AppLog.logTail.isEmpty {
                    Text("Aucun événement — activez le niveau de log.debug ou supérieur pour voir les événements en temps réel.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    LogTailView(search: $searchQuery, minSeverity: Binding(
                        get: { minSeverity ?? 0 },
                        set: { if $0 == 0 { minSeverity = nil } else { minSeverity = $0 } }
                    ))
                    .frame(height: 250)
                }

                HStack(spacing: 8) {
                    Button("Vider le journal") { AppLog.clearLogTail() }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(AppLog.logTail.count) événements au total").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Crash Reports Section

    private var crashReportsSection: some View {
        let hasCrashes = !crashes.reports.isEmpty || !crashes.systemCrashes.isEmpty
        return Section("Rapports de crash (\(crashes.reports.count + crashes.systemCrashes.count))") {
            if !crashes.reports.isEmpty {
                LabeledContent("Crashs applicatifs (\(crashes.reports.count))") {
                    ForEach(crashes.reports.reversed()) { report in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(.caption2, design: .monospaced))
                            Text(report.errorMessage)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                        }
                    }
                }
            }

            if !crashes.systemCrashes.isEmpty {
                LabeledContent("Crashs système (\(crashes.systemCrashes.count))") {
                    ForEach(crashes.systemCrashes.reversed()) { entry in
                        Text("\(entry.processName) — \(entry.summaryLine)")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    }
                }
            }

            if !hasCrashes {
                Text("Aucun crash enregistré.")
                    .foregroundStyle(.secondary)
            }

            // Device info when there are crashes
            if hasCrashes {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(AppCrashReporter.deviceInfo.sorted { $0.key < $1.key }), id: \.key) { k, v in
                        HStack(spacing: 4) {
                            Text(k).font(.caption).foregroundStyle(.secondary)
                            Text(v).font(.system(.caption, design: .monospaced)).foregroundStyle(.primary)
                        }
                    }
                }
            }

            // Crash context if available
            if let ctx = crashes.lastContext {
                LabeledContent("Contexte au crash") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model: \(ctx.modelId ?? "unknown")")
                            .font(.system(.caption, design: .monospaced))
                        Text("Server: \(ctx.serverURL ?? "unknown")")
                            .font(.system(.caption, design: .monospaced))
                        Text("Turns: \(ctx.turnCount)")
                            .font(.system(.caption, design: .monospaced))
                        Text("Uptime: \(String(format: "%.1f", ctx.uptimeSeconds / 60))min")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        Section {
            Button(role: .destructive) { showingResetAlert = true } label: {
                Label("Réinitialiser les métriques", systemImage: "trash")
            }
        }
        .alert("Réinitialiser", isPresented: $showingResetAlert) {
            Button("Supprimer", role: .destructive) { metrics.reset() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cela supprimera tout l'historique des métriques et coûts. Cette action est irréversible.")
        }
    }

    // MARK: - Helpers

    private func statTile(_ label: String, _ value: String, systemImage: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .fontWeight(.semibold)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    private func turnRow(_ m: TurnMetric) -> some View {
        HStack(spacing: 8) {
            Image(systemName: m.isError ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(m.isError ? .red : .green)
                .font(.caption)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(m.modelId) · \(m.provider)")
                    .font(.system(.caption, design: .monospaced))
                HStack(spacing: 12) {
                    Text("in:\(m.tokensInput)".count > 0 ? "\(m.tokensInput)" : "-").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    Text("out:\(m.tokensOutput)".count > 0 ? "\(m.tokensOutput)" : "-").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    Text(formatCost(m.costUSD)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    Text("\(m.latencyMs) ms").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    private func formatCost(_ cost: Double) -> String {
        if cost >= 1 { "$\(String(format: "%.2f", cost))" }
        else if cost >= 0.01 { String(format: "$%.3f", cost) }
        else { String(format: "$%.4f", cost) }
    }
}

// MARK: - Log Tail View

/// Scrollable, searchable log tail with severity filtering. */
struct LogTailView: View {
    @Binding var search: String
    @Binding var minSeverity: Int?

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredEvents) { evt in
                    logRow(evt)
                }
            }
            .font(.system(.caption2, design: .monospaced))
        }
    }

    private var filteredEvents: [LogEvent] {
        var events = AppLog.logTail.filter {
            guard let min = minSeverity else { return true }
            return $0.severity >= min
        }
        if !search.isEmpty {
            let q = search.lowercased()
            events = events.filter {
                $0.source.contains(q) || $0.message.lowercased().contains(q)
            }
        }
        // Limit rendering to last N entries for performance. */
        return Array(events.suffix(500))
    }

    private func logRow(_ evt: LogEvent) -> some View {
        return HStack(spacing: 6) {
            // Severity badge
            Circle()
                .fill(Color(severityColorName(evt.severity)))
                .frame(width: 6, height: 6)

            // Timestamp
            Text(formatter.string(from: evt.date))
                .foregroundStyle(.secondary.opacity(0.8))

            // Source + message
            VStack(alignment: .leading, spacing: 1) {
                if let code = evt.errorCode {
                    HStack(spacing: 4) {
                        Text("[\(code)]").foregroundStyle(.orange).fontWeight(.medium)
                        Text(evt.message)
                            .foregroundStyle(textColor(evt.severity))
                    }
                } else {
                    Text(evt.message)
                        .foregroundStyle(textColor(evt.severity))
                }

                if evt.severity >= AppLog.Level.error.levelInt {
                    Text("[\(evt.source)]").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary.opacity(0.6))
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(evt.severity >= AppLog.Level.error.levelInt ? Color.red.opacity(0.05) : Color.clear)
    }

    private func severityColorName(_ sev: Int) -> String {
        switch sev {
        case 1: return "red"
        case 2: return "orange"
        case 3: return "blue"
        case 4: return "green"
        case 5: return "purple"
        default: return "gray"
        }
    }

    private func textColor(_ sev: Int) -> Color {
        switch sev {
        case 1, 2: return .primary
        case 3: return .secondary
        default: return .secondary.opacity(0.7)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview {
    NavigationView {
        DiagnosticDashboardView()
            .environmentObject(AppSettings.shared)
    }
}
#endif
