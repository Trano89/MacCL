import Foundation

/// Maintains a live connection to the local proxy so macOS doesn't prune it
/// while the app is in the background or between turns.  Pings run even when
/// no conversation is active — this is what keeps the Ollama bridge alive on
/// remote servers and prevents the "app stopped working after switching apps" bug.
@MainActor
final class KeepAlivePinger {

    // MARK: - Configuration

    /// Interval between keep-alive pings.  Short enough to stay within HTTP idle timeouts.
    private let pingInterval: TimeInterval = 15

    // MARK: - State

    private var timerTask: Task<Void, Never>?
    private(set) var isRunning = false
    private var lastPingError: String?

    /// Proxy URL that gets pinged (http://127.0.0.1:<port>)
    private var targetURL: URL?

    // MARK: - Lifecycle

    /// Start pinging the proxy at the given port.  Stops any previous timer first.
    func start(port: Int) {
        stop()
        let url = URL(string: "http://127.0.0.1:\(port)/health")
        guard let u = url else { return }
        targetURL = u

        timerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.pingInterval) * 1_000_000_000)
                } catch { break }

                // Ping — ignore errors; they just mean the proxy is temporarily down.
                let err = await self.pingOnce(url: u)
                if let e = err {
                    self.lastPingError = e
                } else {
                    self.lastPingError = nil  // reset on success
                }
            }
        }
        isRunning = true
    }

    /// Stop the background pinger.
    func stop() {
        timerTask?.cancel()
        timerTask = nil
        isRunning = false
        lastPingError = nil
    }

    // MARK: - Internal helpers

    private func pingOnce(url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                return "status \(code)"
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Check whether the proxy was last seen alive.  Returns `nil` if no ping has run yet.
    var isHealthy: Bool? { lastPingError == nil && targetURL != nil }
}
