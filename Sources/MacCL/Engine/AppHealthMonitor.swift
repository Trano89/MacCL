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
        // Force an immediate heal — the router almost certainly died while backgrounded.
        Task { await self.forceHeal() }
    }

    // MARK: - Health checks

    private func periodicHealthCheck() async {
        guard !isAppBackgrounded, !isHealing else { return }

        let healthy = await Self.checkRouterHealth(port: AppSettings.shared.routerPort)

        if healthy {
            failCount = 0
        } else {
            failCount += 1
            if failCount >= healThreshold {
                await self.heal()
            }
        }
    }

    /// Force a full heal right now — used on foreground transition.
    private func forceHeal() async {
        guard !isHealing else { return }
        await self.heal()
    }

    private func heal() async {
        guard !isHealing else { return }
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
}
