import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    @State private var scanning = false
    @State private var scannedOnce = false
    @State private var discovered: [OllamaDiscovery.Server] = []

    private var detectedClaude: String {
        BinaryLocator.find("claude", override: settings.claudePathOverride) ?? "introuvable"
    }
    private var detectedNode: String {
        BinaryLocator.find("node") ?? "introuvable"
    }

    private static let ctxPresets = [8192, 16384, 32768, 65536, 131072, 262144]
    private static let predictPresets = [0, -1, 2048, 8192, 32768]

    var body: some View {
        Form {
            Section("Claude Code") {
                LabeledContent("Binaire détecté") {
                    Text(detectedClaude)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(detectedClaude == "introuvable" ? .red : .secondary)
                        .textSelection(.enabled)
                }
                TextField("Chemin personnalisé (optionnel)", text: $settings.claudePathOverride)
                    .font(.system(.caption, design: .monospaced))
                Picker("Mode de permission par défaut", selection: Binding(
                    get: { settings.permissionMode },
                    set: { settings.permissionMode = $0 }
                )) {
                    ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                }
            }

            serverSection
            contextSection

            Section("Routeur local") {
                Toggle("Afficher les réflexions du modèle", isOn: $settings.showReasoning)
                Text("Active le raisonnement des modèles locaux (plus lent) et l'affiche dans un panneau sous la conversation. Pour les modèles Anthropic, le raisonnement suit le niveau d'effort.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(value: $settings.routerPort, in: 1024...65535) {
                    LabeledContent("Port du routeur local", value: "\(settings.routerPort)")
                }
                LabeledContent("Node détecté") {
                    Text(detectedNode)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(detectedNode == "introuvable" ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }

            Section("À propos") {
                LabeledContent("Version", value: "ClaudeMac 0.1.0")
                Text("Interface native pour Claude Code. Tous les outils du CLI sont pilotés via le protocole stream-json.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
    }

    // MARK: - Server discovery

    private var serverSection: some View {
        Section("Serveur Ollama") {
            HStack {
                TextField("URL du serveur", text: $settings.ollamaBaseURL)
                    .font(.system(.caption, design: .monospaced))
                Button(action: { Task { await scan() } }) {
                    if scanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Scanner", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(scanning)
            }

            if !discovered.isEmpty {
                ForEach(discovered) { server in
                    Button {
                        settings.ollamaBaseURL = server.url
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: settings.ollamaBaseURL == server.url
                                  ? "checkmark.circle.fill" : "server.rack")
                                .foregroundStyle(settings.ollamaBaseURL == server.url ? Theme.accent : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(server.host)
                                Text("\(server.modelCount) modèle(s) · \(server.url)")
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
                Text("Aucun serveur trouvé. Sur un serveur distant, lancez Ollama avec `OLLAMA_HOST=0.0.0.0 ollama serve` pour l'exposer au réseau.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("« Scanner » cherche les serveurs Ollama (port 11434) en local et sur votre réseau.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func scan() async {
        scanning = true
        discovered = await OllamaDiscovery.discover(port: 11434, configured: settings.ollamaBaseURL)
        scannedOnce = true
        scanning = false
    }

    // MARK: - Context & tokens

    private var contextSection: some View {
        Section("Contexte & tokens") {
            Picker("Fenêtre de contexte (num_ctx)", selection: $settings.ollamaNumCtx) {
                Text("8 192").tag(8192)
                Text("16 384 — recommandé").tag(16384)
                Text("32 768").tag(32768)
                Text("65 536").tag(65536)
                Text("131 072").tag(131072)
                Text("262 144 — max modèle").tag(262144)
                if !Self.ctxPresets.contains(settings.ollamaNumCtx) {
                    Text("\(settings.ollamaNumCtx) (perso)").tag(settings.ollamaNumCtx)
                }
            }
            HStack {
                Text("Valeur personnalisée")
                Spacer()
                TextField("num_ctx", value: $settings.ollamaNumCtx, format: .number)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.caption, design: .monospaced))
            }
            Text("Fenêtre de contexte (l'équivalent du « max tokens » d'Ollama) : jusqu'au maximum du modèle — 262 144 (256k) pour les qwen3. ⚠️ Plus c'est grand, plus le modèle réserve de RAM.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Réponse max (num_predict)", selection: $settings.ollamaMaxPredict) {
                Text("Auto — suit Claude Code").tag(0)
                Text("Illimité — jusqu'au contexte").tag(-1)
                Text("2 048").tag(2048)
                Text("8 192").tag(8192)
                Text("32 768").tag(32768)
                if !Self.predictPresets.contains(settings.ollamaMaxPredict) {
                    Text("\(settings.ollamaMaxPredict) (perso)").tag(settings.ollamaMaxPredict)
                }
            }
            Text("Tokens générés au maximum par réponse (toujours borné par le contexte).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
