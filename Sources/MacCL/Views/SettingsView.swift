import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("Général", systemImage: "gearshape") }
            DiagnosticDashboardView()
                .tabItem { Label("Diagnostics", systemImage: "chart.line.uptrend.xyaxis") }
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

    @State private var litellmInstalling = false
    @State private var litellmMessage = ""
    @State private var litellmFailed = false

    private var detectedClaude: String {
        BinaryLocator.find("claude", override: settings.claudePathOverride) ?? L10n.t("not_found")
    }
    private var detectedNode: String {
        BinaryLocator.find("node") ?? L10n.t("not_found")
    }

    /// Valid context window range for Ollama models.
    /// 1024 is the minimum useful context; 262144 (256k) is the max many recent
    /// models (qwen3, etc.) support. Large values reserve a lot of RAM.
    private static let ctxRange = 1024...262_144

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

            // The Ollama server is a per-conversation choice now — it's asked
            // in the new-conversation sheet, not a global preference.
            Section(L10n.t("conv_server")) {
                Text(L10n.t("server_per_conv_note"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            bridgeSection

            Section(L10n.t("local_router")) {
                Toggle(L10n.t("show_reasoning"), isOn: $settings.showReasoning)
                Text(L10n.t("reasoning_hint"))
                    .foregroundStyle(.secondary)
                Stepper(value: $settings.routerPort, in: 1024...65535) {
                    LabeledContent(L10n.t("router_port"), value: "\(settings.routerPort)")
                }
                LabeledContent(L10n.t("node_detected")) {
                    Text(detectedNode)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(detectedNode == L10n.t("not_found") ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }

            contextSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Bridge engine (built-in router vs LiteLLM)

    private var bridgeSection: some View {
        Section(L10n.t("bridge_engine")) {
            Picker(L10n.t("bridge_engine"), selection: Binding(
                get: { settings.bridgeEngine },
                set: { settings.bridgeEngine = $0 }
            )) {
                ForEach(BridgeEngine.allCases) { Text($0.label).tag($0) }
            }
            Text(settings.bridgeEngine.explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.bridgeEngine == .litellm {
                LabeledContent(L10n.t("litellm_status")) {
                    if litellmInstalling {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(litellmMessage)
                                .foregroundStyle(.secondary)
                        }
                    } else if ModelRouter.shared.litellm.isInstalled {
                        Text(L10n.t("litellm_installed"))
                            .foregroundStyle(.green)
                    } else {
                        Button(L10n.t("litellm_install")) { installLiteLLM() }
                    }
                }
                if !litellmMessage.isEmpty && !litellmInstalling {
                    Text(litellmMessage)
                        .foregroundStyle(litellmFailed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Stepper(value: $settings.litellmPort, in: 1024...65535) {
                    LabeledContent(L10n.t("litellm_port"), value: "\(settings.litellmPort)")
                }
            }
        }
    }

    private func installLiteLLM() {
        litellmInstalling = true
        litellmFailed = false
        litellmMessage = ""
        Task {
            let err = await ModelRouter.shared.litellm.install { step in
                Task { @MainActor in litellmMessage = step }
            }
            litellmInstalling = false
            litellmFailed = err != nil
            litellmMessage = err ?? L10n.t("litellm_install_ok")
        }
    }

    // MARK: - Context section (num_ctx / num_predict with range validation)

    private var contextSection: some View {
        Section(L10n.t("context_tokens")) {
            Picker(L10n.t("context_window"), selection: $settings.ollamaNumCtx) {
                Text("8 192").tag(8192)
                Text("16 384 — \(L10n.t("recommended"))").tag(16_384)
                Text("32 768").tag(32_768)
                Text("65 536").tag(65_536)
                Text("131 072").tag(131_072)
                Text("262 144 — \(L10n.t("model_max"))").tag(262_144)
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
    static let ctxPresets = [8192, 16384, 32768, 65536, 131_072, 262_144]
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

    // PayPal "donate to an email" flow — opens PayPal pre-filled for this address.
    private static let donateEmail = "antonin.trottet@gmail.com"
    private static let donateURL = URL(string:
        "https://www.paypal.com/donate/?business=antonin.trottet%40gmail.com&currency_code=CHF")!

    @State private var showThanks = false

    var body: some View {
        Form {
            Section(L10n.t("about")) {
                LabeledContent(L10n.t("version"), value: "MacCL 0.2.0")
                Text(L10n.t("about_text"))
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("donate")) {
                VStack(alignment: .leading, spacing: 8) {
                    // Developer credit
                    Text(L10n.t("thanks_by"))
                        .foregroundStyle(.secondary)

                    Divider()

                    // Support paragraph
                    Text(L10n.t("thanks_support"))
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

                    // The address, so it's verifiable and usable in the PayPal app.
                    Text(verbatim: Self.donateEmail)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
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

