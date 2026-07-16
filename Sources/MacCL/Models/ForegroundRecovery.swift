import Foundation
import AppKit

/// Detects when the app becomes active again (was in background) and triggers
/// health checks + auto-reconnect of the proxy bridge.  This is what makes the
/// remote Ollama connection survive alt-tab / switch-app scenarios.
final class ForegroundRecovery {

    /// Callback fired on a foreground→background transition.
    var onDeactivate: (() -> Void)?
    /// Callback fired on a background→foreground transition (app went active after being in background).
    var onActivateFromBackground: (() -> Void)?
    /// True while the app is actively in the foreground (no recent deactivate).
    var isActive = true

    private var lastDeactivateTime: Date?
    private let cooldown: TimeInterval = 2.0  // ignore rapid de/activate flashes

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.onDidResign() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.onDidActivate() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notification handlers (always on main thread via queue: .main)

    private func onDidResign() {
        lastDeactivateTime = Date()
        isActive = false
        onDeactivate?()
    }

    private func onDidActivate() {
        // Debounce: only treat it as a real background→foreground transition
        // if enough time has passed since the last deactivate (ignore rapid toggles).
        guard let last = lastDeactivateTime,
              Date().timeIntervalSince(last) > cooldown else { return }

        isActive = true
        onActivateFromBackground?()
    }
}
