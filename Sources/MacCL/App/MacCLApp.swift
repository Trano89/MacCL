import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app owns no server-side state to release on quit: `claude` talks
        // straight to Ollama, and how long a model stays resident is the server's
        // own OLLAMA_KEEP_ALIVE. Nothing to unload, nothing to leak.
        //
        // Reclaim disk from the retired LiteLLM bridge (a Python venv left over
        // from older versions). Off the main thread — it's hundreds of MB.
        Task.detached(priority: .utility) { AppPaths.removeRetiredLiteLLMLeftovers() }
    }
}

@main
struct MacCLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared
    @StateObject private var coordinator = AppearanceCoordinator.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(coordinator)
                .tint(coordinator.accentColor)
                .frame(minWidth: 900, minHeight: 600)
                // Windows adopt the theme via the coordinator's key-window
                // observer; this covers the very first window at launch.
                .onAppear { coordinator.apply() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(coordinator)
                .tint(coordinator.accentColor)
        }
    }
}
