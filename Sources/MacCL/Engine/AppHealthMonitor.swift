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
    /// Consecutive failed restarts, and the earliest time we may try again.
    private var healAttempts = 0
    private var nextHealAllowed = Date.distantPast

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

        if delegate?.isTurnInFlight == true {
            // A *live* bridge must never be restarted mid-turn — that kills the
            // in-flight request. But if the process itself is gone, the turn is
            // already lost, and staying quiet is what left the user watching
            // "working…" forever. Say so, then heal.
            if ModelRouter.shared.bridgeProcessAlive(settings: AppSettings.shared) {
                failCount = 0
                return
            }
            AppLog.write("health", "bridge process died mid-turn — turn is lost, notifying")
            delegate?.turnBrokenByBridgeDeath()
        }
        // Anthropic models talk straight to the API: there is no bridge to probe,
        // and probing anyway means reporting "unhealthy" forever over nothing.
        guard delegate?.usesBridge == true else {
            failCount = 0
            return
        }

        let healthy = await ModelRouter.shared.bridgeHealthy(settings: AppSettings.shared)

        if healthy {
            failCount = 0
            healAttempts = 0
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
        // A restart that fails must not be retried every 16 s forever — that only
        // fills the log and hides the real cause.
        guard Date() >= nextHealAllowed else { return }

        isHealing = true
        defer { isHealing = false; failCount = 0 }

        AppLog.write("health", "bridge unhealthy \(failCount)× — restarting (attempt \(healAttempts + 1))")
        delegate?.willRestartRouter()

        // The delegate owns the process, so it does the real work. This used to
        // return nil unconditionally, so "healing" restarted nothing at all: the
        // monitor announced a restart that never happened, then said so again 16 s
        // later, forever, while the bridge stayed dead.
        if let err = await delegate?.restartBridge() {
            healAttempts += 1
            let wait = min(300, pow(2, Double(healAttempts)) * 15)
            nextHealAllowed = Date().addingTimeInterval(wait)
            AppLog.write("health", "restart failed: \(err) — next attempt in \(Int(wait))s")
            delegate?.healFailed(error: err)
            return
        }

        healAttempts = 0
        nextHealAllowed = .distantPast
        AppLog.write("health", "bridge restarted")
        delegate?.routerDidRestart()
    }
}

/// Protocol for health monitor callbacks to ChatViewModel.
@MainActor
protocol HealthDelegate: AnyObject {
    func willRestartRouter()
    func routerDidRestart()
    func healFailed(error: String)
    /// Actually stop and restart the bridge. Returns nil on success, else why not.
    func restartBridge() async -> String?
    /// The bridge process died while a turn was in flight: the turn is lost.
    /// End it visibly instead of letting "working…" run forever.
    func turnBrokenByBridgeDeath()
    /// True while a turn is in flight. Restarting the router mid-turn kills the
    /// in-flight request and leaves `claude` hanging forever, so healing must wait.
    var isTurnInFlight: Bool { get }
    /// True only when the selected model goes through a local bridge.
    var usesBridge: Bool { get }
}
