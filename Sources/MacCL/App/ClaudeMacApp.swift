import SwiftUI
import AppKit

/// Releases the resident Ollama model(s) and stops the router when the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Anti-AppNap: we prevent macOS from throttling this process by keeping it
        // as a regular app (not accessory/prohibited).  macOS only applies App Nap
        // to apps with windows that are in the background and not receiving input,
        // so a regular activation policy gives us the best chance of staying alive.
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            ModelRouter.shared.cleanupOnQuit()
        }
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
                .accentColor(settings.accentColor)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    AppearanceCoordinator.shared.applyTo(NSApplication.shared.mainWindow)
                }
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
                .accentColor(settings.accentColor)
        }
    }
}
