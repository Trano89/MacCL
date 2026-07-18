# Implementation Plan: Workspace Panel, Ollama Network, Standby Servers, Vertical Toolbar

## Feature 1: Workspace Panel (Agent Monitor)

### Files to create:
- **`Sources/MacCL/Views/WorkspacePanel.swift`** — New rich workspace view (replaces minimal AgentMonitorPanel inline content)

### Files to modify:

#### `Sources/MacCL/ViewModels/ChatViewModel.swift`
- **Line 49**: The existing `agentMonitor` property (`AgentMonitorModel`) is sufficient; it already tracks active agents and their states. No changes needed to the model itself.
- **No state added** — the existing `showAgentMonitor` boolean (a @State in ChatView) already serves as the toggle control.

#### `Sources/MacCL/Models/AgentMonitor.swift`
- **Line 1 (file is mostly empty)**: This file exists but has no content. The AgentState / AgentMonitorParser types live elsewhere. Verify that the parser's `parseTaskInput` and `updateResult` methods feed a proper `AgentMonitorModel` class (likely in AgentMonitorPanel.swift or inline). No code changes needed if AgentMonitorModel is already defined — just ensure it exposes:
  - `var agents: [AgentState]` (already has this via the parser)
  - `var fileAccessEvents: [FileEvent]` (new — add this to track file read/write patterns from stderr or tool calls)
  - `var terminalOutput: String` (new — capture last N KB of Claude Code stdout for the workspace view)

#### `Sources/MacCL/Engine/ClaudeSession.swift`
- Add a new callback closure property:
  ```swift
  var onStdout: ((String) -> Void)?
  ```
- Wire this in `ChatViewModel.wire()` (line ~380) to capture stdout chunks and feed them into the workspace panel's terminal output.

#### `Sources/MacCL/Views/ChatView.swift`
- **Lines 13, 15-17**: `showAgentMonitor` boolean and `showAgentLink` computed property already exist and serve as the toggle mechanism. Keep as-is.
- **Lines 36-40**: Replace the current inline `AgentMonitorPanel` with the new `WorkspacePanel`. Change:
  ```swift
  // FROM (lines 36-40):
  if showAgentMonitor && vm.agentMonitor.hasActiveAgents {
      AgentMonitorPanel(monitor: vm.agentMonitor, onClose: { showAgentMonitor = false })
          .frame(width: geo.size.width * 0.32)
          .transition(.move(edge: .trailing))
  }
  // TO:
  if showAgentMonitor {
      WorkspacePanel(viewModel: vm)
          .frame(width: geo.size.width * 0.35)
          .transition(.move(edge: .trailing))
  }
  ```
- **Lines 80-99**: Enhance the `agent_link` button to show richer content:
  ```swift
  // FROM (lines 81-98): keep the Button but add a label indicator for collapsed state
  // TO: Add a count badge showing active agent count + file access count
  ```
- **Add `.toolbar()` or `.buttonStyle()` modifier** to ensure the `agent_link` button visually indicates panel open vs closed state (e.g., filled vs outlined icon).

#### `Sources/MacCL/Views/WorkspacePanel.swift` (NEW FILE)
- New file containing:
  ```swift
  struct WorkspacePanel: View {
      @ObservedObject var vm: ChatViewModel
      @State private var isExpanded = true
      // ...
      var body: some View {
          VStack(spacing: 0) {
              panelHeader  // Close button + collapsible chevron
              tabSelector  // "Agents" | "Files" | "Terminal" tabs
              Divider()
              tabContent   // switches based on selected tab
          }
          .frame(minWidth: 280, maxWidth: 400)
      }
  }
  ```
- **panelHeader**: HStack with close button (X), panel title "Workspace", and a collapsible chevron (^/v) that toggles `isExpanded` to show/hide the tabSelector for maximum space.
- **tabSelector**: SegmentedControl or custom pill-style tabs for:
  - "Agents" — lists active/pending/completed Task agents (reuse AgentState data from vm.agentMonitor)
  - "Files" — shows file access patterns (new FileEvent model + data from ClaudeSession stdout parsing)
  - "Terminal" — live scrollable terminal output buffer (new terminalOutput string from ClaudeSession onStdout callback)
- **tabContent**: Three ViewBuilders for each tab's content. Agents tab reuses existing AgentMonitor logic but with richer layout (status dots, names, descriptions). Files and Terminal are new views.

### New types needed:
- `struct FileEvent: Identifiable` — `timestamp: Date`, `path: String`, `accessType: String` (read/write/exec)
- WorkspacePanel needs to parse Claude Code stdout for file events (look for patterns like `[ReadFile] path/to/file` in the output).

### Dependencies between features:
- Depends on Feature 3 (Standby Servers) only indirectly — workspace panel should show which server URL is active during the current session.

---

## Feature 2: Ollama Network Provider

### Files to modify:

#### `Sources/MacCL/Models/LLMModel.swift`
- **Line 6**: Add new `.ollamaNetwork` case to `Provider` enum:
  ```swift
  enum Provider: String, Codable {
      case anthropic
      case ollama          // local Ollama only (existing)
      case ollamaNetwork   // remote Ollama server (new)
  }
  ```
- **Lines 9-14**: Update the `label` computed property:
  ```swift
  var label: String {
      switch self {
      case .anthropic: return "Anthropic"
      case .ollama: return "Ollama · local"
      case .ollamaNetwork: return "Ollama · network"  // new case
      }
  }
  ```

#### `Sources/MacCL/ViewModels/ChatViewModel.swift`
- **Line 25 (`availableModels` init)**: No change needed — models are populated in `refreshModels()`.
- **Lines 283-301 (`refreshModels`)**: This is the key modification. Currently it only lists from `settings.ollamaBaseURL`:
  ```swift
  // ADD at line ~285, before the existing ollama list:
  var networkServers = await OllamaDiscovery.discover(port: 11434, configured: settings.ollamaBaseURL)

  // Modify the ollama fetch to tag provider type:
  var ollamaNetworkModels: [LLMModel] = []
  for server in networkServers {
      let models = await OllamaClient.listModels(baseURL: server.url)
      for model in models {
        var m = model
        m.provider = .ollamaNetwork   // tag as network provider
        m.name = "[\(server.host)] \(model.name)"  // prefix with host
        ollamaNetworkModels.append(m)
      }
  }

  // Add to availableModels (around line ~296):
  models += ollamaNetworkModels
  ```
- **Lines 74-78**: Wire a new refresh trigger for standby server changes. Add:
  ```swift
  settings.$standbyServers
      .dropFirst()
      .debounce(for: .seconds(0.15), scheduler: RunLoop.main)
      .sink { [weak self] _ in Task { await self?.refreshModels() } }
      .store(in: &cancellables)
  ```

#### `Sources/MacCL/Views/PickerSheets.swift`
- **Model picker sheet**: Update `ModelPickerSheet` to group models by provider section. The new `.ollamaNetwork` models should appear in a separate "Network Ollama Servers" section, with each server as a subsection. Add visual indicator (e.g., network icon) next to network-sourced models to distinguish them from local Ollama models.

#### `Sources/MacCL/Engine/OllamaClient.swift`
- No changes needed — already supports arbitrary baseURL. The existing `listModels(baseURL:)` method is generic.

### New files: none required (OllamaDiscovery already exists and works generically for any host).

---

## Feature 3: Standby Servers

### Files to create:
- **None** — StandbyServer.swift was referenced in git status but appears empty (1-line file). The model can live inline in AppSettings or be added here.

### Files to modify:

#### `Sources/MacCL/Models/AppSettings.swift`
- **Lines 26-33**: Replace the existing single `ollamaBaseURL` property with a pair of new properties:
  ```swift
  /// List of standby Ollama servers saved by the user.
  @Published var standbyServers: [StandbyServer] {
      didSet {
          let encoder = JSONEncoder()
          if let data = try? encoder.encode(oldValue) {
              defaults.set(data, forKey: "standbyServers")
          }
      }
  }

  /// Index into standbyServers of the currently active server. -1 = use discovery scan only.
  @Published var activeServerIndex: Int {
      didSet { defaults.set(activeServerIndex, forKey: "activeServerIndex") }
  }

  /// Convenience property returning the URL of the active server, or "" if none.
  var ollamaBaseURL: String {
      get { standbyServers.indices.contains(activeServerIndex)
            ? standbyServers[activeServerIndex].url : "" }
      set {
          // Setter matches an existing standby server by URL, or appends it.
          if let idx = standbyServers.firstIndex(where: { $0.url == newValue }) {
              activeServerIndex = idx
              return
          }
          // Create temporary entry (not yet saved until user confirms).
      }
  }
  ```
- **Lines 83-100 (`init`)**: Load standby servers from UserDefaults:
  ```swift
  private init() {
      // ... existing properties ...

      let encoder = JSONDecoder()
      if let data = defaults.data(forKey: "standbyServers"),
         let servers = try? decoder.decode([StandbyServer].self, from: data) {
          standbyServers = servers
      } else {
          standbyServers = [StandbyServer(url: "http://localhost:11434", label: "Localhost", autoDiscover: true)]
      }
      activeServerIndex = defaults.integer(forKey: "activeServerIndex")

      // ollamaBaseURL is now a computed property — remove the old @Published var.
  }
  ```

#### `Sources/MacCL/Models/StandbyServer.swift` (NEW FILE if not already populated)
- New file containing:
  ```swift
  struct StandbyServer: Identifiable, Codable, Hashable {
      let id = UUID()
      var label: String       // display name, e.g. "Office NAS", "Home Mac"
      var url: String         // http://host:port
      var autoDiscover: Bool  // also probe this host via OllamaDiscovery
      var lastDiscoveredAt: Date?
      let addedAt = Date()

      /// Whether this server is currently reachable. Computed from discovery results.
      var isReachable: Bool { lastDiscoveredAt != nil }

      /// Default localhost entry, used as initial value.
      static let localhost = StandbyServer(label: "Localhost", url: "http://localhost:11434", autoDiscover: true)
  }
  ```

#### `Sources/MacCL/ViewModels/ChatViewModel.swift`
- **`refreshModels()` (lines 283-301)**: Add standby server scanning. Before listing models, scan all standby servers that have `autoDiscover == true`:
  ```swift
  // After the existing ollama list (line ~296):
  var discoveredNetworkServers = await OllamaDiscovery.discover(
      port: 11434,
      configured: ""
  )
  for server in discoveredNetworkServers {
      let models = await OllamaClient.listModels(baseURL: server.url)
      // Add each as .ollamaNetwork type (see Feature 2 plan).
  }
  ```

#### `Sources/MacCL/Views/NewConversationSheet.swift`
- **Model picker sheet**: When the user picks a model from `.ollamaNetwork`, detect which standby server it came from and set that as the active server before starting the conversation. If the model came from a discovered-but-not-saved server, prompt to save it as a new standby server.

#### `Sources/MacCL/Views/SettingsView.swift`
- **Add "Ollama Servers" section**: UI for managing standby servers:
  ```swift
  Section("Ollama Servers") {
      List($settings.standbyServers) { $server in
          HStack {
              TextField("Label", text: $server.label)
              TextField("URL", text: $server.url)
                  .keyboardType(.URL)
              Button(action: { /* discover models */ }) {
                  Image(systemName: "magnifyingglass")
              }
              Spacer()
          }
      }
      .onDelete(perform: deleteStandbyServer)
      Button("Add Server") { settings.standbyServers.append(.init(label: "", url: "http://", autoDiscover: true)) }
  }
  ```

#### `Sources/MacCL/Engine/ClaudeSession.swift`
- **`SessionConfig`**: Ensure the `ollamaBaseURL` field uses `settings.ollamaBaseURL` (now a computed property) rather than a raw string from settings. No structural change needed if SessionConfig already accepts a `String` for baseURL.

### Migration concern:
- Users upgrading will have no `standbyServers` key in UserDefaults. The init fallback creates `[StandbyServer.localhost]` with `activeServerIndex = 0`, which preserves the pre-existing localhost-only behavior automatically.

---

## Feature 4: Vertical Icon Column

### Files to modify:

#### `Sources/MacCL/Views/ChatView.swift`
- **Lines 159-189**: Replace the horizontal HStack in the composer's bottom-bar section with a vertical VStack on the right side. The key structural change is wrapping the TextField and its border in an HStack where the left side is the text area and the right side is the icon column:

  ```swift
  // Lines 142-190 (the composer's VStack → new structure):
  HStack(spacing: 8) {
      // LEFT: text field with auto-expansion
      VStack(spacing: 6) {
          TextField(L10n.t("write_placeholder"), text: $vm.composer, axis: .vertical)
              .textFieldStyle(.plain)
              .font(.body)
              .lineLimit(1...10)
              .padding(12)
              .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
              .overlay(
                  RoundedRectangle(cornerRadius: Theme.corner)
                      .stroke(composerFocused ? composerAccent.opacity(0.6) : Theme.hairline)
              )
              .frame(minHeight: 36)
              .focused($composerFocused)
      }

      // RIGHT: vertical icon column
      VStack(spacing: 10) {
          Spacer()
          Button(action: pickFiles) {
              Image(systemName: "paperclip")
                  .font(.title2)
          }
          .buttonStyle(.borderless)
          .frame(width: 32, height: 32)

          Button { showSlashCommands = true } label: {
              Image(systemName: "slash.circle")
                  .font(.title2)
          }
          .buttonStyle(.borderless)
          .frame(width: 32, height: 32)

          Group {
              if vm.isRunning {
                  Button(action: vm.stop) {
                      Image(systemName: "stop.fill")
                          .font(.title2)
                  }
                  .tint(.secondary)
              } else {
                  Button(action: vm.send) {
                      Image(systemName: "arrow.up")
                          .font(.title2)
                  }
                  .tint(settings.accentColor)
                  .disabled(!vm.canSend)
              }
          }
          .buttonStyle(.borderless)
          .frame(width: 32, height: 32)
      }
      .padding(.vertical, 14)
  }
  ```

- **Lines 222-299 (controlsBar)**: Move the horizontal controls bar (model, permission, effort, folder, instructions buttons) from below the composer to a NEW location — the TOP of the chat area as a toolbar row above the transcript. This keeps all controls accessible without cluttering the input area:
  ```swift
  // Add to ChatView.body, between GeometryReader root and VStack:
  HStack(spacing: 6) {
      modelMenu
      permissionMenu
      effortMenu
      folderButton
      instructionsButton
      Spacer()
  }
  .padding(.horizontal, 16)
  .padding(.vertical, 4)
  ```
- Remove the `controlsBar` property entirely (lines 224-233) since its contents are now inlined above.
- The composer section no longer has a `.padding(16)` on its outer VStack — instead, use individual padding values to control spacing precisely between the text field area and the icon column.

### Layout changes summary:
```
BEFORE:                     AFTER:
+-------------------------+  +-----------------------------------+
| controls bar (H)       |  | [model] [perm] [effort] [...]    |  <-- controls moved up
+-------------------------+  +-----------------------------------+
|                         |  |                                   |
|  [transcript area]     |  |  [transcript area]              |
|                         |  |                                   |
+-------------------------+  +-----------------------------------+
| text field [attach][/]|  |  text field                      |
|         [send/stop H]  |  |         ↕                        |  <-- vertical icons
+-------------------------+  |   [📎]  [⊘]  [↑]              |
| controls bar (H)       |  |         ↕                        |
+-------------------------+  +-----------------------------------+
```

### Files to modify:
- **`Sources/MacCL/Views/ChatView.swift`**: Composer layout (lines 159-189), controlsBar relocation (lines 222-299).
- No other files need changes for this feature.

---

## Cross-Feature Integration Points

### Conversation start flow:
1. User sends message → `ChatViewModel.send()` (line 108) → `launchOrContinue()` (line 306).
2. Before launching, check `AppSettings.activeServerIndex` to determine which Ollama server to use for model selection. If -1, scan all standby servers + auto-discover.
3. If the selected model is `.ollamaNetwork`, set `ANTHROPIC_BASE_URL` in the extra environment to that server's URL (not the router port).
4. The workspace panel shows the active server URL in a status area.

### Model picker grouping:
The `ModelPickerSheet` must display models in this order:
1. **Anthropic** section (existing)
2. **Ollama · local** section (existing localhost models)
3. **Ollama · network** section (new, one subsection per standby server)

### UI state transitions:
- When `AppSettings.standbyServers` changes while a conversation is active, show an alert: "Ollama servers changed — restart current session?"
- Workspace panel collapses automatically when all agents finish (`vm.agentMonitor.hasActiveAgents == false`).

---

## File Summary

### New files (2):
1. `Sources/MacCL/Views/WorkspacePanel.swift` — rich workspace panel with tabs
2. `Sources/MacCL/Models/StandbyServer.swift` — StandbyServer model (if not already created)

### Modified files (8):
1. `Sources/MacCL/ViewModels/ChatViewModel.swift` — refreshModels, standby wiring, availableModels init
2. `Sources/MacCL/Models/LLMModel.swift` — ollamaNetwork provider case
3. `Sources/MacCL/Models/AppSettings.swift` — standbyServers + activeServerIndex + ollamaBaseURL computed property
4. `Sources/MacCL/Views/ChatView.swift` — composer vertical icons, workspace panel integration
5. `Sources/MacCL/Views/PickerSheets.swift` — model picker grouping by provider + network subsections
6. `Sources/MacCL/Views/SettingsView.swift` — standby servers management UI
7. `Sources/MacCL/Engine/ClaudeSession.swift` — add onStdout callback for terminal output streaming
8. `Sources/MacCL/Models/AgentMonitor.swift` — ensure AgentMonitorModel class exists with agents, fileAccessEvents, terminalOutput

### No changes needed:
- `Sources/MacCL/Engine/OllamaDiscovery.swift` — already works generically
- `Sources/MacCL/Engine/OllamaClient.swift` — baseURL is generic
- `Sources/MacCL/Engine/ModelRouter.swift` — only routes local; network models skip the router
