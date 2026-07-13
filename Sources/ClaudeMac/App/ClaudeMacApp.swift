import SwiftUI
import AppKit

/// Releases the resident Ollama model(s) and stops the router when the app quits
/// — while the app runs, models stay loaded (keep_alive:-1).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            ModelRouter.shared.cleanupOnQuit(baseURL: AppSettings.shared.ollamaBaseURL)
        }
    }
}

@main
struct ClaudeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
