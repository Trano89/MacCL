import Foundation
import SwiftUI

/// Monitors reachability of standby Ollama servers using periodic HTTP checks.
@MainActor
final class StandbyMonitor: ObservableObject {
    /// Current reachability status per server URL.
    @Published var statusMap: [String: ServerStatus] = [:]

    /// Active task keyed by server ID for cancellable monitoring.
    private var tasks: [String: Task<Void, Never>] = [:]
    private let checkInterval: TimeInterval = 60 // 1 minute

    /// Start monitoring a standby server's availability via periodic ping.
    func startMonitoring(server: StandbyServer) {
        stopMonitoring(serverId: server.id)

        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(checkInterval) * 1_000_000_000)
                } catch { break }

                let available = await OllamaClient.isReachable(baseURL: server.url)
                let next: ServerStatus = available ? .available : .unreachable

                // Only update if status actually changed — avoids unnecessary UI refreshes.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let prev = self.statusMap[server.url] ?? .unknown
                    guard prev != next else { return }
                    self.statusMap[server.url] = next
                }
            }
        }

        tasks[server.id] = task

        // Also do an initial check with a brief jitter to avoid hammering.
        let initTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self else { return }
            let available = await OllamaClient.isReachable(baseURL: server.url)
            let next: ServerStatus = available ? .available : .unreachable
            Task { @MainActor in
                self.statusMap[server.url] = next
            }
        }
        tasks["init-\(server.id)"] = initTask
    }

    /// Stop monitoring a standby server.
    func stopMonitoring(serverId: String) {
        tasks.removeValue(forKey: serverId)?.cancel()
        tasks.removeValue(forKey: "init-\(serverId)")
    }

    /// Stop all monitoring.
    func stopAll() {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
    }

    /// Current reachability state of a standby server.
    enum ServerStatus: String, Identifiable {
        case unknown = "unknown"
        case available = "available"
        case unreachable = "unreachable"

        var id: String { rawValue }
    }
}
