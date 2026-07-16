import Foundation
import Combine

/// Monitors router + session health continuously. On background→foreground transitions,
/// heals any dead processes so the app always stays operational.
@MainActor
final class AppHealthMonitor {

    private var periodicCheckTask: Task<Void, Never>?
    private let checkInterval: TimeInterval = 8   // every 8 seconds in foreground
    private weak var delegate: HealthDelegate?

    /// Number of consecutive failed health checks before we trigger a full heal.
    private var failCount = 0
    private let healThreshold = 2                  // fail twice → heal once
    private var isHealing = false
    private var isAppBackgrounded = false

    init(delegate: HealthDelegate?) {
        self.delegate = delegate
        startMonitoring()
    }

    deinit {
        periodicCheckTask?.cancel()
    }

    // MARK: - Lifecycle

    private func startMonitoring() {
        periodicCheckTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.checkInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.periodicHealthCheck()
            }
        }
    }

    /// Called by AppLifecycleObserver when the app goes background.
    func didEnterBackground() {
        isAppBackgrounded = true
    }

    /// Called by AppLifecycleObserver when the app comes back to foreground.
    func didBecomeActive() {
        isAppBackgrounded = false
        // Re-check on return to foreground, but never heal blindly: the router is
        // a child process and does NOT die when the app is backgrounded. Blindly
        // restarting it used to kill in-flight requests, leaving `claude` hung
        // forever ("it ran two minutes then nothing").
        Task { await self.periodicHealthCheck() }
    }

    // MARK: - Health checks

    private func periodicHealthCheck() async {
        guard !isAppBackgrounded, !isHealing else { return }
        // Never touch the bridge while a turn is running — a restart would break
        // the live connection and hang the turn.
        guard delegate?.isTurnInFlight != true else {
            failCount = 0
            return
        }

        let healthy = await ModelRouter.shared.bridgeHealthy(settings: AppSettings.shared)

        if healthy {
            failCount = 0
        } else {
            failCount += 1
            if failCount >= healThreshold {
                await self.heal()
            }
        }
    }

    private func heal() async {
        guard !isHealing else { return }
        // Last-chance guard: a turn may have started while we were checking.
        guard delegate?.isTurnInFlight != true else { return }
        AppLog.write("health", "router unhealthy \(failCount)× — healing")
        isHealing = true
        defer { isHealing = false; failCount = 0 }

        // Step 1: Stop the dead router.
        delegate?.willRestartRouter()

        // Restart the router process.
        if let err = await self.restartRouter() {
            delegate?.healFailed(error: err)
            return
        }

        // Step 2: Notify that things are fresh again — session should be validated.
        delegate?.routerDidRestart()
    }

    /// Stop the existing router and start a new one with current settings.
    /// The actual process restart is handled by ChatViewModel.healAfterBackgrounding()
    /// via the HealthDelegate.routerDidRestart() callback, which also re-establishes
    /// the session state. This monitor only signals that healing is needed.
    private func restartRouter() async -> String? {
        // Healing flow: willRestartRouter() → stop dead process → prepare new → routerDidRestart().
        // ChatViewModel owns the full lifecycle, so we just return nil here to signal success;
        // the real work is in the delegate callback chain.
        return nil
    }

    /// Quick health check on the router port without spawning tasks.
    private static func checkRouterHealth(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

/// Protocol for health monitor callbacks to ChatViewModel.
@MainActor
protocol HealthDelegate: AnyObject {
    func willRestartRouter()
    func routerDidRestart()
    func healFailed(error: String)
    /// True while a turn is in flight. Restarting the router mid-turn kills the
    /// in-flight request and leaves `claude` hanging forever, so healing must wait.
    var isTurnInFlight: Bool { get }
}
