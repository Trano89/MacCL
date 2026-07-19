import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label(L10n.t("tab_general"), systemImage: "gearshape") }
            AppearanceTab()
                .tabItem { Label(L10n.t("tab_appearance"), systemImage: "swatchpalette") }
            AboutTab()
                .tabItem { Label(L10n.t("about"), systemImage: "info.circle") }
        }
        .frame(width: 560, height: 640)
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @EnvironmentObject var settings: AppSettings

    private var claudePath: String? {
        BinaryLocator.find("claude", override: settings.claudePathOverride)
    }

    var body: some View {
        Form {
            Section("Claude Code") {
                LabeledContent(L10n.t("detected_binary")) {
                    Text(claudePath ?? L10n.t("not_found"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(claudePath == nil ? .red : .secondary)
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

            Section(L10n.t("reasoning")) {
                Toggle(L10n.t("show_reasoning"), isOn: $settings.showReasoning)
                Text(L10n.t("reasoning_hint"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Context size and residency are Ollama's own settings, not ours: the
            // Messages API has no field for either, so pretending to control them
            // from here would be a lie. Say where they actually live.
            Section(L10n.t("ollama_tuning")) {
                Text(L10n.t("ollama_tuning_note"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("OLLAMA_CONTEXT_LENGTH=262144\nOLLAMA_KEEP_ALIVE=30m\nOLLAMA_FLASH_ATTENTION=1\nOLLAMA_KV_CACHE_TYPE=q8_0")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance tab

private struct AppearanceTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var coordinator: AppearanceCoordinator

    /// Le nuancier — curated hues that hold up as tint in both clair and sombre.
    private static let accentColors: [(name: String, hex: Int)] = [
        ("Corail",     0xE37654),
        ("Bleu",       0x4A90D9),
        ("Indigo",     0x6366F1),
        ("Violet",     0x8B5CF6),
        ("Rose",       0xF43F5E),
        ("Rouge",      0xEF4444),
        ("Ambre",      0xF59E0B),
        ("Vert",       0x10B981),
        ("Sarcelle",   0x14B8A6),
        ("Cyan",       0x06B6D4),
        ("Graphite",   0x6B7280),
        ("Brun",       0xA16207),
    ]

    var body: some View {
        Form {
            Section(L10n.t("theme_mode")) {
                Picker("", selection: Binding(
                    get: { coordinator.theme },
                    set: { coordinator.theme = $0 }   // didSet persists + applies to all windows
                )) {
                    ForEach(AppearanceTheme.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section(L10n.t("accent_color")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                         count: 3), spacing: 10) {
                    ForEach(Self.accentColors, id: \.hex) { item in
                        swatch(item)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    private func swatch(_ item: (name: String, hex: Int)) -> some View {
        let isSelected = settings.accentColorHex == item.hex
        let color = Color(
            red: Double((item.hex & 0xFF0000) >> 16) / 255.0,
            green: Double((item.hex & 0x00FF00) >> 8) / 255.0,
            blue: Double(item.hex & 0x0000FF) / 255.0)
        return Button {
            settings.accentColorHex = item.hex
            coordinator.accentChanged()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 24, height: 24)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .overlay(Circle().stroke(isSelected ? color.opacity(0.5) : .clear, lineWidth: 3)
                        .padding(-3))
                Text(item.name)
                    .foregroundStyle(isSelected ? color : .primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - About tab (unchanged)

private struct AboutTab: View {
    @EnvironmentObject var settings: AppSettings

    // PayPal "donate to an email" flow — opens PayPal pre-filled for this address.
    private static let donateEmail = "antonin.trottet@icloud.com"
    private static let donateURL = URL(string:
        "https://www.paypal.com/donate/?business=antonin.trottet%40icloud.com&currency_code=CHF")!

    @State private var showThanks = false
    @State private var checkingUpdate = false
    @State private var updateStatus: String?
    @State private var updateAvailable = false

    var body: some View {
        Form {
            Section(L10n.t("about")) {
                LabeledContent(L10n.t("version"), value: "MacCL \(UpdateChecker.currentVersion)")
                Text(L10n.t("about_text"))
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("updates")) {
                HStack {
                    if checkingUpdate {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("update_checking")).foregroundStyle(.secondary)
                    } else {
                        Button(L10n.t("update_check")) { checkForUpdate() }
                    }
                    Spacer()
                    if updateAvailable {
                        Button {
                            NSWorkspace.shared.open(UpdateChecker.releasesPage)
                        } label: {
                            Label(L10n.t("update_download"), systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                    }
                }
                if let status = updateStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(updateAvailable ? Theme.accent : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    private func checkForUpdate() {
        checkingUpdate = true
        updateStatus = nil
        updateAvailable = false
        Task {
            let (outcome, error) = await UpdateChecker.check()
            checkingUpdate = false
            if let outcome {
                updateAvailable = outcome.isNewer
                updateStatus = outcome.isNewer
                    ? L10n.t("update_available", outcome.latestTag)
                    : L10n.t("update_uptodate")
            } else {
                updateStatus = error
            }
        }
    }

    private func donate() {
        NSWorkspace.shared.open(Self.donateURL)
        showThanks = true
    }
}

// MARK: - Helpers

