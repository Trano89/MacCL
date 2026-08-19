import SwiftUI

/// Manage the models of a (possibly remote) Ollama server, terminal-style:
/// type a command, watch the server answer. Everything goes through Ollama's
/// own HTTP API — nothing to install on the remote machine.
///
///     pull qwen3:14b                      download a model
///     rm   llama3:8b                      delete a model
///     cp   qwen3:8b mon-qwen              duplicate under a new name
///     create mon-qwen from qwen3:8b num_ctx 32768
///                                         derived model with baked-in parameters
///     fix  hf.co/some/repack:Q8_0         rebuild it with a working tool parser
struct ModelManagerView: View {
    let serverURL: String
    let onBack: () -> Void

    @State private var models: [OllamaClient.InstalledModel] = []
    @State private var details: [String: OllamaClient.ModelDetails] = [:]
    @State private var command = ""
    @State private var log: [String] = []
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { onBack() } label: {
                    Label(L10n.t("back"), systemImage: "chevron.left")
                }
                .controlSize(.small)
                Spacer()
                Label(URL(string: serverURL)?.host ?? serverURL, systemImage: "wrench.and.screwdriver")
                    .font(.headline)
                Spacer()
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(busy)
                .accessibilityLabel(L10n.t("refresh"))
            }
            .padding(12)
            Divider()

            List {
                Section(L10n.t("installed_models")) {
                    if models.isEmpty {
                        Text(L10n.t("no_models"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(models) { m in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name)
                                    .font(.system(.body, design: .monospaced))
                                if needsRepair(m.name) {
                                    Label(L10n.t("no_tool_parser"), systemImage: "exclamationmark.triangle")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Text(m.sizeBytes.formattedBytes)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            if needsRepair(m.name) {
                                Button {
                                    run("fix \(m.name)")
                                } label: {
                                    Image(systemName: "bandage")
                                        .foregroundStyle(.orange)
                                }
                                .buttonStyle(.plain)
                                .disabled(busy)
                                .help(L10n.t("repair_help"))
                                .accessibilityLabel("\(L10n.t("repair")) \(m.name)")
                            }
                            Button {
                                run("rm \(m.name)")
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                            .accessibilityLabel("\(L10n.t("delete")) \(m.name)")
                        }
                    }
                }

                if !log.isEmpty {
                    Section(L10n.t("cmd_output")) {
                        // Last lines only — a pull emits one line per percent.
                        ForEach(Array(log.suffix(12).enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("✗") ? .red : .secondary)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                Text(">")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                TextField(L10n.t("cmd_placeholder"), text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { runCurrent() }
                    .disabled(busy)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L10n.t("execute")) { runCurrent() }
                        .controlSize(.small)
                        .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
            Text(L10n.t("cmd_hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .frame(width: 480, height: 520)
        .task { await refresh() }
    }

    private func refresh() async {
        models = await OllamaClient.installedModels(baseURL: serverURL)
        // Load every model's directives in parallel — that's what tells us which
        // ones would have to have a tool parser generated for them.
        var map: [String: OllamaClient.ModelDetails] = [:]
        await withTaskGroup(of: (String, OllamaClient.ModelDetails?).self) { group in
            for m in models {
                group.addTask { (m.name, await OllamaClient.details(model: m.name, baseURL: serverURL)) }
            }
            for await (name, d) in group { map[name] = d }
        }
        details = map
    }

    /// Worth offering a repair: the model would need a generated parser, and a
    /// sibling of the same family can lend a built-in one.
    private func needsRepair(_ name: String) -> Bool {
        details[name]?.lacksToolParser == true
            && OllamaClient.parserDonor(for: name, details: details) != nil
    }

    private func runCurrent() {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        command = ""
        run(cmd)
    }

    /// Parse and execute one command against the server.
    private func run(_ cmd: String) {
        let words = cmd.split(separator: " ").map(String.init)
        guard let verb = words.first?.lowercased() else { return }
        log.append("> \(cmd)")
        busy = true
        Task {
            let error: String?
            switch (verb, words.count) {
            case ("pull", 2):
                error = await OllamaClient.pullModel(words[1], baseURL: serverURL) { line in
                    // Progress replaces the previous progress line instead of scrolling.
                    if log.last?.hasPrefix("  ") == true { log[log.count - 1] = "  " + line }
                    else { log.append("  " + line) }
                }
            case ("rm", 2), ("delete", 2):
                error = await OllamaClient.deleteModel(words[1], baseURL: serverURL)
            case ("cp", 3):
                error = await OllamaClient.copyModel(words[1], to: words[2], baseURL: serverURL)
            case ("create", let n) where n >= 4 && words[2].lowercased() == "from":
                // create NAME from BASE [key value]…
                var params: [String: Any] = [:]
                var i = 4
                while i + 1 < words.count {
                    params[words[i]] = Int(words[i + 1]) ?? words[i + 1]
                    i += 2
                }
                error = await OllamaClient.createModel(name: words[1], from: words[3],
                                                       parameters: params, baseURL: serverURL)
            // Split deliberately: a `where` on a multi-pattern case binds only
            // to the last pattern, which the compiler rightly flags as ambiguous.
            case ("fix", 2), ("fix", 4):
                guard words.count == 2 || words[2].lowercased() == "as" else {
                    error = L10n.t("cmd_unknown"); break
                }
                // fix MODEL [as NEWNAME]
                let source = words[1]
                let target = words.count == 4 ? words[3] : OllamaClient.repairedName(for: source)
                if let donor = OllamaClient.parserDonor(for: source, details: details) {
                    log.append("  \(L10n.t("repair_using", donor.parser)) (\(donor.name))")
                }
                error = await OllamaClient.repairToolParser(model: source, as: target,
                                                            details: details, baseURL: serverURL)
                if error == nil { log.append("  → \(target)") }
            default:
                error = L10n.t("cmd_unknown")
            }
            log.append(error.map { "✗ \($0)" } ?? "✓ ok")
            busy = false
            await refresh()
        }
    }
}
