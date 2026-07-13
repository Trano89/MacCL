import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var vm = ChatViewModel(settings: AppSettings.shared)

    var body: some View {
        NavigationSplitView {
            Sidebar(vm: vm)
                .navigationSplitViewColumnWidth(min: 230, ideal: 264, max: 340)
        } detail: {
            ChatView(vm: vm)
        }
        .navigationTitle("ClaudeMac")
    }
}
