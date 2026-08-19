import Foundation

/// Per-turn usage metrics: tokens, cost, latency, errors. */
struct TurnMetric: Codable, Sendable, Identifiable {
    /// Identity for SwiftUI only, never persisted: a `let` with a default is
    /// not decodable, so round-tripping silently minted a new one anyway. Made
    /// explicit rather than left as a warning that reads like a data loss.
    let id = UUID()
    let date: Date
    let modelId: String
    let provider: String
    /// Prompt tokens sent to the model.
    let tokensInput: Int
    /// Completion tokens received from the model.
    let tokensOutput: Int
    let costUSD: Double
    let latencyMs: Int
    let isError: Bool

    private enum CodingKeys: String, CodingKey {
        case date, modelId, provider, tokensInput, tokensOutput, costUSD, latencyMs, isError
    }
}

/// Daily aggregate of cost and tokens — one row per day. */
struct DailyAggregate: Codable, Sendable {
    let day: Date            // midnight UTC start of the day
    let turns: Int
    let costUSD: Double
    let inputTokens: Int
    let outputTokens: Int
    let errorCount: Int
    let avgLatencyMs: Double
}

/// Cumulative summary of all recorded turns. */
struct MetricsSummary: Sendable {
    let turnCount: Int
    let totalCostUSD: Double
    let totalTokens: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let avgLatencyMs: Double
    let medianLatencyMs: Int      // p50
    let p95LatencyMs: Int         // 95th percentile
    let p99LatencyMs: Int         // 99th percentile
    let minLatencyMs: Int
    let maxLatencyMs: Int
    let errorCount: Int
    let errorRate: Double          // 0.0 .. 1.0
    /// Last N metrics for time-series charts. */
    let recentTurns: [TurnMetric]
    /// Per-model breakdown with error rates. */
    let perModelBreakdown: [(modelId: String, turns: Int, costUSD: Double, avgLatencyMs: Double, errorRate: Double)]
    /// Last 30 days of daily aggregation (cost/tokens trend). */
    let dailyTrend: [DailyAggregate]
    /// Turns that exceeded the slow threshold (>20s by default).
    let slowTurns: [(date: Date, latencyMs: Int, modelId: String)]
}

/// AppMetrics tracks per-turn metrics and persists them as a JSON file. */
@MainActor
final class AppMetrics: ObservableObject {
    static let shared = AppMetrics()

    /// Cumulative USD across all recorded turns (survives app restart). */
    @Published var totalCostUSD: Double = 0
    @Published var cumulativeInputTokens: Int = 0
    @Published var cumulativeOutputTokens: Int = 0

    /// Slow-turn threshold in ms — turns above this are flagged. Default 20s.
    static let slowTurnThresholdMs = 20_000

    /// Last N metrics for time-series. Older records are rolled up into summary. */
    @Published private(set) var recentMetrics: [TurnMetric] = []

    /// Full summary computed from persisted + in-memory data. */
    var summary: MetricsSummary {
        let all = recentMetrics
        guard !all.isEmpty else {
            return MetricsSummary(
                turnCount: 0, totalCostUSD: totalCostUSD,
                totalTokens: 0, totalInputTokens: cumulativeInputTokens, totalOutputTokens: cumulativeOutputTokens,
                avgLatencyMs: 0, medianLatencyMs: 0, p95LatencyMs: 0, p99LatencyMs: 0,
                minLatencyMs: 0, maxLatencyMs: 0,
                errorCount: 0, errorRate: 0, recentTurns: [],
                perModelBreakdown: [], dailyTrend: [], slowTurns: []
            )
        }

        // ---- cost / tokens aggregates ----
        let cost = all.reduce(0) { $0 + $1.costUSD }
        let input = all.reduce(0) { $0 + $1.tokensInput }
        let output = all.reduce(0) { $0 + $1.tokensOutput }

        // ---- latency stats ----
        let latencies = all.map(\.latencyMs).sorted()
        let avgLat = Double(latencies.reduce(0, +)) / Double(latencies.count)
        let p50 = percentile(at: 0.50, of: latencies)
        let p95 = percentile(at: 0.95, of: latencies)
        let p99 = percentile(at: 0.99, of: latencies)

        // ---- error stats ----
        let errors = all.filter(\.isError).count

        // ---- per-model breakdown ----
        func modelStats(metrics: [TurnMetric], label: String) -> (modelId: String, turns: Int, costUSD: Double, avgLatencyMs: Double, errorRate: Double) {
            let costs = metrics.map(\.costUSD).reduce(0, +)
            let lats = metrics.map(\.latencyMs).reduce(0, +)
            let errs = metrics.filter(\.isError).count
            return (label, metrics.count, costs, Double(lats) / Double(metrics.count), Double(errs) / Double(metrics.count))
        }

        var modelGroups: [String: [TurnMetric]] = [:]
        for m in all { modelGroups[m.modelId, default: []].append(m) }
        let perModelBreakdown = modelGroups.map { k, v in modelStats(metrics: v, label: k) }.sorted { $0.turns > $1.turns }

        // ---- daily trend (last 30 days) ----
        let dailyTrend = computeDailyTrend(from: all)

        // ---- slow turns ----
        let slowTurns = all.filter { $0.latencyMs > AppMetrics.slowTurnThresholdMs }
            .sorted { $0.date > $1.date }
            .prefix(20)
            .map { ($0.date, $0.latencyMs, $0.modelId) }

        return MetricsSummary(
            turnCount: all.count,
            totalCostUSD: totalCostUSD + cost,
            totalTokens: cumulativeInputTokens + cumulativeOutputTokens + input + output,
            totalInputTokens: cumulativeInputTokens + input,
            totalOutputTokens: cumulativeOutputTokens + output,
            avgLatencyMs: avgLat,
            medianLatencyMs: p50,
            p95LatencyMs: p95,
            p99LatencyMs: p99,
            minLatencyMs: latencies.first ?? 0,
            maxLatencyMs: latencies.last ?? 0,
            errorCount: errors,
            errorRate: Double(errors) / Double(all.count),
            recentTurns: all.suffix(50),
            perModelBreakdown: perModelBreakdown,
            dailyTrend: dailyTrend,
            slowTurns: Array(slowTurns)
        )
    }

    private let metricsFileURL: URL
    private let maxRecent = 500
    private let stateLock = NSLock()

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("MacCL", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        metricsFileURL = dir.appendingPathComponent("metrics.json")
        load()
    }

    // MARK: - Record

    /// Record a single turn's outcome. Call from ChatViewModel when a `result` event arrives. */
    func record(modelId: String, provider: String,
                tokensIn: Int, tokensOut: Int,
                costUSD: Double, latencyMs: Int, isError: Bool) {
        let metric = TurnMetric(
            date: Date(), modelId: modelId, provider: provider,
            tokensInput: tokensIn, tokensOutput: tokensOut,
            costUSD: costUSD, latencyMs: latencyMs, isError: isError
        )
        stateLock.lock()
        defer { stateLock.unlock() }

        recentMetrics.append(metric)

        // These three counters hold ONLY what has been evicted from
        // `recentMetrics`; `summary` adds the live window back on top. Counting
        // the new turn here as well made every figure on the diagnostics
        // dashboard — cost and both token totals — exactly double the truth for
        // as long as the turn stayed in the window.
        if recentMetrics.count > maxRecent {
            let removed = Array(recentMetrics[0 ..< (recentMetrics.count - maxRecent)])
            totalCostUSD += removed.reduce(0) { $0 + $1.costUSD }
            cumulativeInputTokens += removed.reduce(0) { $0 + $1.tokensInput }
            cumulativeOutputTokens += removed.reduce(0) { $0 + $1.tokensOutput }
            recentMetrics.removeFirst(removed.count)
        }

        save()
    }

    /// Reset all metrics to zero. */
    func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }
        recentMetrics.removeAll()
        totalCostUSD = 0
        cumulativeInputTokens = 0
        cumulativeOutputTokens = 0
        try? FileManager.default.removeItem(at: metricsFileURL)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: metricsFileURL),
              let records = try? JSONDecoder().decode([TurnMetric].self, from: data) else { return }
        recentMetrics = records
        // Deliberately NOT seeded from `records`: those turns are the live
        // window, and `summary` already sums them. Setting the cost here made
        // the dashboard read double from the first launch, and it seeded only
        // cost — leaving the token totals to disagree with it.
        //
        // The file stores the retained window only, so what was evicted before
        // a relaunch is not recoverable: totals then describe the turns still
        // on record rather than all time. Correct and stated, instead of a
        // bigger number that is wrong.
        totalCostUSD = 0
        cumulativeInputTokens = 0
        cumulativeOutputTokens = 0
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(recentMetrics),
              FileManager.default.isWritableFile(atPath: metricsFileURL.path) else { return }
        try? data.write(to: metricsFileURL, options: .atomic)
    }

    // MARK: - Helpers

    private func percentile(at fraction: Double, of sortedValues: [Int]) -> Int {
        guard !sortedValues.isEmpty else { return 0 }
        let idx = Int(fraction * Double(sortedValues.count - 1))
        return sortedValues[idx]
    }

    private func computeDailyTrend(from metrics: [TurnMetric]) -> [DailyAggregate] {
        guard !metrics.isEmpty else { return [] }
        let calendar = Calendar.current
        var dailyMap: [Date: (turns: Int, cost: Double, input: Int, output: Int, errors: Int, latencySum: Int)] = [:]

        for m in metrics {
            let dayStart = calendar.startOfDay(for: m.date)
            let existing = dailyMap[dayStart] ?? (0, 0, 0, 0, 0, 0)
            dailyMap[dayStart] = (
                turns: existing.turns + 1,
                cost: existing.cost + m.costUSD,
                input: existing.input + m.tokensInput,
                output: existing.output + m.tokensOutput,
                errors: existing.errors + (m.isError ? 1 : 0),
                latencySum: existing.latencySum + m.latencyMs
            )
        }

        return dailyMap.sorted { $0.key < $1.key }.map { day, agg in
            DailyAggregate(
                day: day,
                turns: agg.turns,
                costUSD: agg.cost,
                inputTokens: agg.input,
                outputTokens: agg.output,
                errorCount: agg.errors,
                avgLatencyMs: Double(agg.latencySum) / Double(agg.turns)
            )
        }.suffix(30)
    }
}
