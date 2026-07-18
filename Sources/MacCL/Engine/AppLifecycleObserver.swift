import Foundation
import Combine
import AppKit

/// Observes app lifecycle (foreground ↔ background) and fires callbacks.
/// Used to detect when the user switches away from / back to MacCL so that
/// we can heal dead router processes and restore streaming sessions.
@MainActor
final class AppLifecycleObserver: ObservableObject {
    enum AppState {
        case foreground
        case background
    }

    @Published var current: AppState = .foreground

    private var cancellables = Set<AnyCancellable>()
    weak var delegate: AppLifecycleDelegate?

    init() {
        let nc = NotificationCenter.default
        nc.publisher(for: NSApplication.willResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.current = .background
                self.delegate?.appDidEnterBackground()
            }
            .store(in: &cancellables)

        nc.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.current = .foreground
                self.delegate?.appDidBecomeActive()
            }
            .store(in: &cancellables)

        // App launch → foreground by default.
        self.current = .foreground
    }

    deinit {
        cancellables.forEach { $0.cancel() }
    }
}

/// Protocol for lifecycle callbacks.
@MainActor
protocol AppLifecycleDelegate: AnyObject {
    func appDidEnterBackground()
    func appDidBecomeActive()
}
