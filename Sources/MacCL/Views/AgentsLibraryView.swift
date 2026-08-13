import SwiftUI

/// Manager for the working folder's sub-agents — the `.claude/agents/*.md`
/// files the `claude` CLI reads on its own.
///
/// The two things this view exists to make possible, and which nothing else in
/// the app could express: giving an agent a *different model*, and pointing it
/// at a *different machine*. Everything else here is the plumbing that keeps
/// those two honest — the model list comes from the machine actually selected,
/// so an agent can't be pointed at a model that isn't there.
struct AgentsLibraryView: View {
    /// The server the conversation itself runs on — the default for any agent
    /// that doesn't name a machine.
    let conversationServerURL: String
    /// Which machine (and folder) the agent files are written to.
    let workLocation: WorkLocation

    @ObservedObject private var store = AgentStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    @State private var draft = AgentsLibraryView.blankDraft
    @State private var isDirty = false
    @State private var saveError: String?
    /// Model names per server URL, fetched lazily as machines are picked.
    @State private var modelsByURL: [String: [String]] = [:]
    @State private var loadingModels = false
    @State private var showDeleteConfirm = false

    private static let blankDraft = AgentDefinition(
        name: "", description: "", tools: [], model: "", serverName: "", prompt: "")

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                agentList
                Divider()
                editor
            }
            Divider()
            bottomBar
        }
        .frame(width: 820, height: 560)
        .task {
            await store.load(location: workLocation)
            if selection == nil, let first = store.agents.first {
                select(first.name)
            }
            await loadModels(for: conversationServerURL)
        }
    }

    // MARK: - List

    private var agentList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section(L10n.t("agents_library")) {
                    ForEach(store.agents) { agent in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.name)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            Text(subtitle(for: agent))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(agent.name)
                    }
                }
            }
            if store.isLoading { ProgressView().controlSize(.small).padding(6) }
        }
        .frame(width: 250)
        .onChange(of: selection) { old, new in
            // Capture the draft BEFORE `select` overwrites it — the save runs
            // asynchronously and would otherwise write the newly-selected agent
            // over the one the user just edited.
            if let old, isDirty {
                let edited = draft
                Task { await persist(edited, replacing: old) }
            }
            if let new { select(new) }
        }
    }

    /// What an agent will actually do, in one line: its model and its machine.
    private func subtitle(for agent: AgentDefinition) -> String {
        let model = agent.model.isEmpty ? L10n.t("agent_model_inherit") : agent.model
        guard !agent.serverName.isEmpty else { return model }
        return "\(model) · \(agent.serverName)"
    }

    // MARK: - Editor

    private var editor: some View {
        Group {
            // `isDirty` matters here: the very first agent has no selection and
            // no saved sibling yet, and without it the form the user is typing
            // into would be replaced by the "no agents" placeholder.
            if selection == nil && store.agents.isEmpty && !isDirty {
                VStack(spacing: 12) {
                    Text(L10n.t("agents_library_empty"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button { newAgent() } label: {
                        Label(L10n.t("agent_new"), systemImage: "plus")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                editorForm
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                field(L10n.t("agent_name")) {
                    TextField("", text: Binding(
                        get: { draft.name },
                        set: { draft.name = AgentDefinition.sanitizeName($0) ?? ""; isDirty = true }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                field(L10n.t("agent_when")) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: Binding(
                            get: { draft.description },
                            set: { draft.description = $0; isDirty = true }
                        ), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        Text(L10n.t("agent_when_hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    field(L10n.t("agent_machine")) { machinePicker }
                    field(L10n.t("agent_model")) { modelPicker }
                }

                field(L10n.t("agent_prompt")) {
                    TextEditor(text: Binding(
                        get: { draft.prompt },
                        set: { draft.prompt = $0; isDirty = true }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
                }

                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    private func field<Content: View>(_ label: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The machine the agent runs on. "The conversation's server" is not a
    /// cosmetic default: it is the case that needs no router at all.
    private var machinePicker: some View {
        Picker("", selection: Binding(
            get: { draft.serverName },
            set: { name in
                draft.serverName = name
                // A model from the old machine may not exist on the new one.
                draft.model = ""
                isDirty = true
                Task { await loadModels(for: baseURL(for: name)) }
            }
        )) {
            Text(L10n.t("agent_machine_same")).tag("")
            ForEach(settings.standbyServers) { server in
                Text(server.name.isEmpty ? server.displayHost : server.name)
                    .tag(server.name)
            }
        }
        .labelsHidden()
    }

    private var modelPicker: some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(
                get: { draft.model },
                set: { draft.model = $0; isDirty = true }
            )) {
                Text(L10n.t("agent_model_inherit")).tag("")
                ForEach(modelsByURL[baseURL(for: draft.serverName)] ?? [], id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            if loadingModels { ProgressView().controlSize(.small) }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button { newAgent() } label: { Label(L10n.t("new"), systemImage: "plus") }
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label(L10n.t("delete"), systemImage: "trash")
                }
                .disabled(selection == nil)
                Spacer()
                Button(L10n.t("save")) { Task { await persistDraft() } }
                    .keyboardShortcut("s")
                    .disabled(draft.name.isEmpty)
                Button(L10n.t("close")) {
                    Task {
                        if isDirty, !draft.name.isEmpty { await persistDraft() }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .tint(Theme.accent)
            }

            concurrencyRow

            HStack(spacing: 6) {
                Image(systemName: workLocation.isLocal ? "folder" : "network")
                    .foregroundStyle(.secondary)
                Text(L10n.t("agents_dir_note", AgentStore.directory(for: workLocation.path)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }

            let unresolved = store.unresolvedServerNames(known: settings.standbyServers)
            if !unresolved.isEmpty {
                Label(L10n.t("agents_unknown_server", unresolved.joined(separator: ", ")),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .confirmationDialog(L10n.t("agent_delete_confirm"), isPresented: $showDeleteConfirm) {
            Button(L10n.t("delete"), role: .destructive) { Task { await deleteSelected() } }
            Button(L10n.t("cancel"), role: .cancel) {}
        }
    }

    /// The serial/parallel dial. Worth showing beside the agents themselves:
    /// it is the difference between one model resident and several fighting.
    private var concurrencyRow: some View {
        HStack(spacing: 10) {
            Text(L10n.t("concurrency_title"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Stepper(value: $settings.maxConcurrentSubagents, in: 1...20) {
                Text(settings.maxConcurrentSubagents == 1
                     ? L10n.t("concurrency_serial")
                     : "\(settings.maxConcurrentSubagents)")
                    .font(.caption.monospacedDigit())
            }
            .fixedSize()

            if !settings.standbyServers.isEmpty {
                Divider().frame(height: 14)
                Text(L10n.t("concurrency_per_server"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Stepper(value: $settings.maxConcurrentPerServer, in: 1...20) {
                    Text("\(settings.maxConcurrentPerServer)")
                        .font(.caption.monospacedDigit())
                }
                .fixedSize()
            }

            Text(L10n.t("concurrency_hint"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    // MARK: - Actions

    private func baseURL(for serverName: String) -> String {
        guard !serverName.isEmpty else { return conversationServerURL }
        return settings.standbyServers.first { $0.name == serverName }?.url ?? ""
    }

    private func select(_ name: String) {
        guard let agent = store.agents.first(where: { $0.name == name }) else { return }
        draft = agent
        selection = name
        isDirty = false
        saveError = nil
        Task { await loadModels(for: baseURL(for: agent.serverName)) }
    }

    private func newAgent() {
        Task {
            if isDirty, !draft.name.isEmpty { await persistDraft() }
            draft = Self.blankDraft
            draft.name = uniqueName()
            draft.description = ""
            draft.prompt = ""
            selection = nil
            isDirty = true
        }
    }

    private func uniqueName() -> String {
        let existing = Set(store.agents.map(\.name))
        var candidate = "agent"
        var n = 2
        while existing.contains(candidate) {
            candidate = "agent-\(n)"
            n += 1
        }
        return candidate
    }

    private func persistDraft() async {
        guard !draft.name.isEmpty else { return }
        saveError = await store.save(draft, location: workLocation)
        if saveError == nil {
            isDirty = false
            selection = draft.name
        }
    }

    /// Save a specific edit, which may have been renamed away from `original`.
    private func persist(_ edited: AgentDefinition, replacing original: String) async {
        guard !edited.name.isEmpty else { return }
        saveError = await store.save(edited, location: workLocation)
        // A rename leaves the old file behind — remove it rather than ending up
        // with two agents the model can both see.
        if saveError == nil, original != edited.name,
           let stale = store.agents.first(where: { $0.name == original }) {
            await store.delete(stale, location: workLocation)
        }
    }

    private func deleteSelected() async {
        guard let name = selection,
              let agent = store.agents.first(where: { $0.name == name }) else { return }
        saveError = await store.delete(agent, location: workLocation)
        selection = store.agents.first?.name
        if let selection { select(selection) } else { draft = Self.blankDraft }
    }

    /// Fetch a machine's model list once, so the model picker only ever offers
    /// models that exist where the agent will run.
    private func loadModels(for url: String) async {
        guard !url.isEmpty, modelsByURL[url] == nil else { return }
        loadingModels = true
        defer { loadingModels = false }
        let models = await OllamaClient.listModels(baseURL: url)
        modelsByURL[url] = models.map(\.modelArg).sorted()
    }
}
