import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    @State private var scanning = false
    @State private var scannedOnce = false
    @State private var discovered: [OllamaDiscovery.Server] = []

    var body: some View {
        TabView {
            GeneralTab(scanning: $scanning, scannedOnce: $scannedOnce, discovered: $discovered)
                .tabItem { Label("Général", systemImage: "gearshape") }
            AppearanceTab()
                .tabItem { Label("Apparence", systemImage: "swatchpalette") }
            AboutTab()
                .tabItem { Label("À propos", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 640)
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @EnvironmentObject var settings: AppSettings

    // Use environment state from parent SettingsView to avoid duplicate scanning state.
    @Binding var scanning: Bool
    @Binding var scannedOnce: Bool
    @Binding var discovered: [OllamaDiscovery.Server]

    @State private var addingSource: ServerAddSource = .manual
    @State private var manualUrl = ""

    // MARK: - Server health check state

    /// Health status for each standby server — keyed by its unique ID.
    /// `nil` means no check has run yet (shows dashed circle icon).
    @State private var serverHealth: [String: Bool] = [:]   // true=reachable, false=unreachable

    // MARK: - Delete confirmation sheet

    /// ID of the server pending removal; nil hides the confirmation dialog.
    @State private var pendingRemoveId: String?

    private var detectedClaude: String {
        BinaryLocator.find("claude", override: settings.claudePathOverride) ?? L10n.t("not_found")
    }
    private var detectedNode: String {
        BinaryLocator.find("node") ?? L10n.t("not_found")
    }

    /// Valid context window range for Ollama models.
    /// 1024 is the minimum useful context; 131072 covers most models' KV-cache limits
    /// without risking out-of-memory on typical Mac hardware.
    private static let ctxRange = 1024...131_072

    /// Valid num_predict range for user-enterable presets (special values -1 and 0 excluded).
    private static let predictUserRange = 128...65_536

    var body: some View {
        Form {
            Section("Claude Code") {
                LabeledContent(L10n.t("detected_binary")) {
                    Text(detectedClaude)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(detectedClaude == "introuvable" ? .red : .secondary)
                        .textSelection(.enabled)
                }
                TextField(L10n.t("custom_path"), text: $settings.claudePathOverride)
                    .font(.system(.caption, design: .monospaced))
                Picker(L10n.t("default_permission"), selection: Binding(
                    get: { settings.permissionMode },
                    set: { settings.permissionMode = $0 }
                )) {
                    ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                }
            }

            serverSection

            Section(L10n.t("local_router")) {
                Toggle(L10n.t("show_reasoning"), isOn: $settings.showReasoning)
                Text(L10n.t("reasoning_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(value: $settings.routerPort, in: 1024...65535) {
                    LabeledContent(L10n.t("router_port"), value: "\(settings.routerPort)")
                }
                LabeledContent(L10n.t("node_detected")) {
                    Text(detectedNode)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(detectedNode == "introuvable" ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }

            contextSection
        }
        .formStyle(.grouped)
        // Confirmation sheet for server deletion — prevents accidental removal.
        .confirmationDialog(
            L10n.t("confirm_remove_server_title"),
            isPresented: Binding(
                get: { pendingRemoveId != nil },
                set: { if !$0 { pendingRemoveId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.t("confirm_yes"), role: .destructive) {
                if let id = pendingRemoveId {
                    settings.removeStandbyServer(id: id)
                    serverHealth.removeValue(forKey: id)
                    pendingRemoveId = nil
                }
            }
        } message: {
            if let server = standbyServerWithId(pendingRemoveId ?? "") {
                Text(L10n.t("confirm_remove_server_message", server.name))
            }
        }
    }

    // MARK: - Server section with real-time validation

    private var serverSection: some View {
        Section(L10n.t("ollama_server")) {
            // Primary server URL field with live validation feedback.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField(
                        L10n.t("add_server_placeholder"),
                        text: $settings.ollamaBaseURL
                    )
                        .font(.system(.caption, design: .monospaced))

                    Button(action: { Task { await scan() } }) {
                        if scanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L10n.t("scan"), systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                    .disabled(scanning)
                }

                // Live validation bar — shows green/red status based on URL validity.
                validationBar(text: settings.ollamaBaseURL)
            }

            if !discovered.isEmpty {
                ForEach(discovered) { server in
                    Button {
                        settings.ollamaBaseURL = server.url
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: settings.ollamaBaseURL == server.url
                                  ? "checkmark.circle.fill" : "server.rack")
                                .foregroundStyle(settings.ollamaBaseURL == server.url
                                    ? settings.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(server.host)
                                Text("\(server.modelCount) \(L10n.t("models_count")) · \(server.url)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else if scannedOnce && !scanning {
                Text(L10n.t("no_server_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.t("scan_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("standby_servers")) {
                if !settings.standbyServers.isEmpty {
                    ForEach(settings.standbyServers) { server in
                        standbyServerRow(server: server)
                    }
                }

                Picker("", selection: $addingSource) {
                    Text(L10n.t("manual_entry")).tag(ServerAddSource.manual)
                    if !discovered.isEmpty { Text(L10n.t("scan")).tag(ServerAddSource.discovered) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                // Add server row with live URL validation on the input field.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField(L10n.t("enter_url"), text: $manualUrl)
                            .font(.system(.caption, design: .monospaced))
                            .textFieldStyle(.roundedBorder)

                        Button(action: { Task { await addServer() } }) {
                            Text(L10n.t("add"))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        // Disable add button unless the URL validates.
                        .disabled(manualUrl.isEmpty || !isValidatedURL(manualUrl))
                    }

                    // Inline validation feedback — text turns green/red based on real-time state.
                    if !manualUrl.isEmpty {
                        let (color, icon) = validationIndicator(manualUrl)
                        HStack(spacing: 4) {
                            Image(systemName: icon)
                                .font(.caption2)
                            Text(color == .green ? L10n.t("url_valid") : L10n.t("url_invalid_scheme"))
                                .font(.caption2)
                        }
                        .foregroundStyle(color.opacity(0.85))
                    }
                }
            }
        }
    }

    // MARK: - Standby server row

    /// Single row for a standby server with health indicator, active toggle, and delete button.
    private func standbyServerRow(server: StandbyServer) -> some View {
        let idx = settings.standbyServers.firstIndex { $0.id == server.id } ?? -1
        let isActive = settings.currentStandbyIndex != nil &&
                       settings.standbyServers[settings.currentStandbyIndex!] == server

        return VStack(spacing: 2) {
            HStack(spacing: 8) {
                // Health indicator — small icon that reflects live server connectivity.
                healthView(for: server)

                // Server name and URL.
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)

                    Text(server.url)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Remote server warning — yellow for non-localhost servers.
                if let url = URL(string: server.url),
                   url.host != "localhost" && url.host != "127.0.0.1" {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange.opacity(0.7))
                        .help(L10n.t("remote_server_warning"))
                }

                // Activate button — switches this server to the active URL.
                if idx >= 0 {
                    Button(action: { Task { await activateServer(at: idx) } }) {
                        Image(systemName: "arrow.right.circle")
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("standby_active"))

                    // Delete button — triggers confirmation dialog via pendingRemoveId.
                    Button(action: { pendingRemoveId = server.id }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("remove_server"))
                }
            }

            // Active label when this server is the current one.
            if isActive {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(settings.accentColor)
                    Text(L10n.t("standby_active"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(settings.accentColor.opacity(0.8))
                }
            }
        }
    }

    // MARK: - Health indicator

    /// Colored icon reflecting the server's live health status.
    private func healthView(for server: StandbyServer) -> some View {
        let reachable = serverHealth[server.id]
        let (icon, color) = switch reachable {
        case .some(true):  ("checkmark.circle.fill", Color.green)
        case .some(false): ("xmark.circle.fill",     .red)
        case .none:        ("circle.dashed",         .secondary)
        }
        return Image(systemName: icon)
            .foregroundStyle(color)
            .font(.caption2)
            .onAppear {
                guard serverHealth[server.id] == nil else { return }
                Task {
                    let reachable = await OllamaClient.isReachable(baseURL: server.url)
                    await MainActor.run { serverHealth[server.id] = reachable }
                }
            }
    }

    // MARK: - URL validation helpers

    /// Check if a text is a valid (possibly sanitized) server URL.
    private func isValidatedURL(_ text: String) -> Bool {
        !text.isEmpty && URLValidator.sanitizeAndValidate(text) != nil
    }

    /// Validation indicator tuple — (color, systemIcon) for inline feedback.
    private func validationIndicator(_ text: String) -> (color: SwiftUI.Color, icon: String) {
        guard let _ = URLValidator.sanitizeAndValidate(text) else {
            return (.red, "exclamationmark.triangle")
        }
        return (.green, "checkmark.circle.fill")
    }

    /// Validation bar shown below the primary server URL field.
    private func validationBar(text: String) -> some View {
        let isValid = !text.isEmpty && URLValidator.sanitizeAndValidate(text) != nil
        return HStack(spacing: 4) {
            Image(systemName: isValid ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .font(.caption2)
            Text(isValid ? L10n.t("url_valid") : L10n.t("url_empty"))
                .font(.caption2)
        }
        .foregroundStyle(isValid ? .green.opacity(0.85) : .red.opacity(0.85))
    }

    // MARK: - Actions

    private func scan() async {
        scanning = true
        discovered = await OllamaDiscovery.discover(port: 11434, configured: settings.ollamaBaseURL)
        scannedOnce = true
        scanning = false
    }

    /// Add a server from the manual entry field with validation and health check.
    /// URLValidator.sanitizeAndValidate handles scheme auto-fix, so the user can type
    /// "localhost:11434" and it becomes "http://localhost:11434" behind the scenes.
    private func addServer() async {
        guard !manualUrl.isEmpty else { return }

        // Validate and sanitize — prevents adding malformed servers.
        guard let _ = URLValidator.sanitizeAndValidate(manualUrl) else {
            // User sees the red validation bar above; no crash, just rejected input.
            return
        }

        var urlToUse: String
        if manualUrl.hasPrefix("http://") || manualUrl.hasPrefix("https://") {
            urlToUse = manualUrl.trimmingCharacters(in: .whitespaces)
        } else {
            urlToUse = "http://" + manualUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let parsed = URL(string: urlToUse),
              let host = parsed.host, !host.isEmpty else { return }

        // Prevent adding the same host multiple times (e.g. duplicate localhost entries).
        let existingHosts = Set(settings.standbyServers.map { $0.displayHost.lowercased() })
        guard !existingHosts.contains(host.lowercased()) else { return }

        // Check reachability BEFORE adding the server to the persistent list.
        guard await OllamaClient.isReachable(baseURL: urlToUse) else {
            return
        }

        let displayPort = parsed.port ?? 11434
        let serverName = (displayPort == 11434) ? host : "\(host):\(displayPort)"
        let server = StandbyServer(name: serverName, url: urlToUse)

        // Deduplicate by URL — same as AppSettings.addStandbyServer behavior.
        var list = settings.standbyServers
        list.removeAll { $0.url == server.url }
        list.append(server)
        settings.standbyServers = list

        // Record health status (true because we already checked reachability above).
        await MainActor.run { serverHealth[server.id] = true }

        manualUrl = ""
    }

    /// Activate a standby server at the given index, with health verification.
    private func activateServer(at index: Int) async {
        guard let err = await settings.activateStandby(at: index) else { return }
        // If activation fails (e.g., server unreachable), the user sees the red health indicator.
        _ = err
    }

    private func standbyServerWithId(_ id: String) -> StandbyServer? {
        settings.standbyServers.first { $0.id == id }
    }

    // MARK: - Context section (num_ctx / num_predict with range validation)

    private var contextSection: some View {
        Section(L10n.t("context_tokens")) {
            Picker(L10n.t("context_window"), selection: $settings.ollamaNumCtx) {
                Text("8 192").tag(8192)
                Text("16 384 — \(L10n.t("recommended"))").tag(16_384)
                Text("32 768").tag(32_768)
                Text("65 536").tag(65_536)
                Text("131 072 — \(L10n.t("model_max"))").tag(131_072)
                if !Self.ctxPresets.contains(settings.ollamaNumCtx) {
                    // Clamp to valid range to prevent out-of-bounds persistence.
                    let clamped = max(Self.ctxRange.lowerBound, min(Self.ctxRange.upperBound, settings.ollamaNumCtx))
                    Text("\(clamped) (\(L10n.t("custom_value")))").tag(clamped)
                }
            }

            // Custom num_ctx value with range hint visible at all times.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.t("custom_value"))
                    Spacer()
                    TextField("num_ctx", value: $settings.ollamaNumCtx, format: .number)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.caption, design: .monospaced))
                }
                Text("\(L10n.t("ctx_min")) · \(L10n.t("ctx_max"))")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.6))
            }

            Text(L10n.t("ctx_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(L10n.t("max_reply"), selection: $settings.ollamaMaxPredict) {
                Text(L10n.t("auto_follow")).tag(0)
                Text(L10n.t("unlimited")).tag(-1)
                Text("2 048").tag(2048)
                Text("8 192").tag(8192)
                Text("32 768").tag(32_768)
            }

            // Custom num_predict value with range hint visible at all times.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.t("custom_value"))
                    Spacer()
                    TextField("num_predict", value: $settings.ollamaMaxPredict, format: .number)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.caption, design: .monospaced))
                }
                Text("\(L10n.t("predict_min")) · \(L10n.t("predict_max"))")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.6))
            }

            Text(L10n.t("predict_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Preset context window sizes — used for picker display and custom value detection.
private extension GeneralTab {
    static let ctxPresets = [8192, 16384, 32768, 65536, 131_072]
}

// MARK: - Appearance tab (unchanged)

private struct AppearanceTab: View {
    @EnvironmentObject var settings: AppSettings
    @State private var coordinator = AppearanceCoordinator.shared

    // 8 curated accent colors (hex RGB integers)
    private static let accentColors: [(name: String, hex: Int)] = [
        ("Coral",      0xE37654),
        ("Blue",       0x4A90D9),
        ("Purple",     0x8B5CF6),
        ("Green",      0x10B981),
        ("Red",        0xEF4444),
        ("Teal",       0x14B8A6),
        ("Amber",      0xF59E0B),
        ("Rose",       0xF43F5E),
    ]

    // Display name -> raw value mapping for the theme mode picker
    private let themeLabels = [
        ("Système", "system"),
        ("Clair",   "light"),
        ("Sombre",  "dark"),
    ]

    var body: some View {
        Form {
            Section(L10n.t("theme_mode")) {
                Picker("", selection: Binding(
                    get: { settings.appearanceThemeRaw },
                    set: {
                        settings.appearanceThemeRaw = $0
                        AppearanceCoordinator.shared.theme = AppearanceTheme(rawValue: $0) ?? .system
                    }
                )) {
                    ForEach(themeLabels, id: \.1) { Text($0.0).tag($0.1) }
                }
                .pickerStyle(.inline)
            }

            Section(L10n.t("accent_color")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<Self.accentColors.count / 4, id: \.self) { row in
                        HStack(spacing: 16) {
                            ForEach(0..<4, id: \.self) { col in
                                let idx = row * 4 + col
                                if idx < Self.accentColors.count {
                                    colorSwatch(Self.accentColors[idx])
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func colorSwatch(_ item: (name: String, hex: Int)) -> some View {
        let isSelected = settings.accentColorHex == item.hex
        return Button {
            settings.accentColorHex = item.hex
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(
                        red: Double((item.hex & 0xFF0000) >> 16) / 255.0,
                        green: Double((item.hex & 0x00FF00) >> 8) / 255.0,
                        blue: Double(item.hex & 0x0000FF) / 255.0
                    ))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? settings.accentColor : Color.clear, lineWidth: 3)
                    )
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }

                Text(item.name)
                    .foregroundStyle(isSelected ? settings.accentColor : .primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - About tab (unchanged)

private struct AboutTab: View {
    @EnvironmentObject var settings: AppSettings

    // TODO(<ant @your_paypal_username>): replace with your actual paypal.me link, e.g. https://paypal.me/MacCL
    private static let donateURL = URL(string: "https://paypal.me/MacCL")!

    @State private var showThanks = false

    var body: some View {
        Form {
            Section(L10n.t("about")) {
                LabeledContent(L10n.t("version"), value: "MacCL 0.1.0")
                Text(L10n.t("about_text"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("donate")) {
                VStack(alignment: .leading, spacing: 8) {
                    // Developer credit
                    Text(L10n.t("thanks_by"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    // Support paragraph
                    Text(L10n.t("thanks_support"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // PayPal donation button
                    Button(action: donate) {
                        HStack(spacing: 8) {
                            Image(systemName: "heart.circle.fill")
                                .font(.title2)
                            VStack(alignment: .leading) {
                                Text(L10n.t("donate"))
                                    .fontWeight(.semibold)
                                Text("via PayPal")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(settings.accentColor.opacity(0.12))
                        .foregroundColor(settings.accentColor)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("donate") + " via PayPal")
                }
            }

            if showThanks {
                Section(L10n.t("tab_thanks")) {
                    Text(L10n.t("thanks_note"))
                        .font(.headline)
                        .foregroundStyle(settings.accentColor)
                }
            }
        }
        .formStyle(.grouped)
        .onOpenURL { url in
            if url.host == "www.paypal.com" || url.host == "paypal.me" || url.host == "www.paypal.me" {
                showThanks = true
            }
        }
    }

    private func donate() {
        NSWorkspace.shared.open(Self.donateURL)
        showThanks = true
    }
}

// MARK: - Helpers

private enum ServerAddSource: String, CaseIterable {
    case manual
    case discovered
}
