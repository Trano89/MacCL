import SwiftUI
import AppKit

/// Choose where a conversation works: a folder on this Mac, or one on an SSH
/// machine — browsed live, since you can't drag a remote path into an open panel.
///
/// The host editor is a MODE of this sheet rather than a sheet of its own:
/// nested sheets have bitten this app before, and the flow is linear anyway
/// (pick a machine → browse it → confirm).
struct WorkLocationSheet: View {
    let initial: WorkLocation
    /// nil = cancelled. The caller owns dismissal, so this view works both as a
    /// real sheet (from the chat toolbar) and as a mode inside another sheet
    /// (the new-conversation form) — where calling `dismiss()` would close the
    /// wrong window.
    let onFinish: (WorkLocation?) -> Void

    @ObservedObject private var store = SSHHostStore.shared

    private enum Mode: Int { case local, ssh }
    @State private var mode: Mode = .local
    @State private var localPath = ""

    @State private var selectedHostId = ""
    @State private var remotePath = ""
    @State private var listing: SSHClient.Listing?
    @State private var loading = false
    @State private var failure: SSHClient.Failure?
    /// Non-nil while the host editor is on screen (a new or existing machine).
    @State private var editingHost: SSHHost?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    /// Set while `restoreInitialSelection` seeds mode and host, so the reactive
    /// handlers below don't each fire their own connection for the same restore.
    @State private var restoring = false

    private var selectedHost: SSHHost? { store.host(id: selectedHostId) }

    var body: some View {
        Group {
            if let host = editingHost {
                SSHHostEditor(host: host) { saved in
                    editingHost = nil
                    guard let saved else {
                        // Cancelled — or the machine was deleted, in which case
                        // the selection and its listing now point at nothing.
                        if store.host(id: selectedHostId) == nil {
                            selectedHostId = store.hosts.first?.id ?? ""
                            listing = nil
                            failure = nil
                        }
                        return
                    }
                    // Seed the selection without letting the reactive handlers
                    // fire their own connection, then browse the machine once.
                    restoring = true
                    selectedHostId = saved.id
                    mode = .ssh
                    listing = nil
                    failure = nil
                    Task {
                        restoring = false
                        await open(saved.lastPath.isEmpty ? "~" : saved.lastPath)
                    }
                }
            } else {
                picker
            }
        }
        .frame(width: 620, height: 560)
        .onAppear(perform: restoreInitialSelection)
    }

    private func restoreInitialSelection() {
        localPath = initial.isLocal
            ? initial.path
            : FileManager.default.homeDirectoryForCurrentUser.path
        restoring = true
        if !initial.isLocal, store.host(id: initial.hostId) != nil {
            mode = .ssh
            selectedHostId = initial.hostId
            Task {
                restoring = false
                await open(initial.path)
            }
        } else {
            mode = .local
            selectedHostId = store.hosts.first?.id ?? ""
            restoring = false
        }
    }

    // MARK: - Main picker

    private var picker: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.t("work_location"), systemImage: "externaldrive.connected.to.line.below")
                    .font(.title3.bold())
                Spacer()
            }
            .padding(14)

            Picker("", selection: $mode) {
                Label(L10n.t("location_local"), systemImage: "desktopcomputer").tag(Mode.local)
                Label(L10n.t("location_ssh"), systemImage: "network").tag(Mode.ssh)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            // Switching TO the SSH pane is what asks for a connection — that's
            // the click the user just made, so the wait is expected here.
            .onChange(of: mode) { _, newMode in
                guard !restoring, newMode == .ssh, listing == nil, failure == nil,
                      let host = selectedHost else { return }
                Task { await open(host.lastPath.isEmpty ? "~" : host.lastPath) }
            }

            Divider()

            if mode == .local { localPane } else { sshPane }

            Divider()
            HStack {
                if mode == .ssh, let host = selectedHost {
                    Text(host.detailedTarget)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(L10n.t("cancel")) { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("use_this_folder"), action: commit)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!canCommit)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private var canCommit: Bool {
        mode == .local ? !localPath.isEmpty : (listing != nil && selectedHost != nil)
    }

    private func commit() {
        if mode == .local {
            onFinish(.local(localPath))
        } else {
            guard let host = selectedHost, let listing else { return }
            store.rememberPath(listing.path, forHost: host.id)
            onFinish(WorkLocation(hostId: host.id, path: listing.path))
        }
    }

    // MARK: - Local

    private var localPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("location_local_hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(Theme.accent)
                Text(displayLocalPath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(L10n.t("choose"), action: chooseLocalFolder)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.corner))
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var displayLocalPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return localPath.hasPrefix(home) ? "~" + localPath.dropFirst(home.count) : localPath
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: localPath)
        if panel.runModal() == .OK, let url = panel.url { localPath = url.path }
    }

    // MARK: - SSH

    private var sshPane: some View {
        VStack(spacing: 0) {
            hostBar
            Divider()
            if selectedHost == nil {
                emptyHostState
            } else {
                pathBar
                Divider()
                browser
            }
        }
    }

    private var hostBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $selectedHostId) {
                ForEach(store.hosts) { host in
                    Text(host.label).tag(host.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            .disabled(store.hosts.isEmpty)
            // Only browse while the SSH pane is actually showing. Seeding the
            // picker's selection also fires this, and connecting to a machine
            // the user hasn't asked to see is a surprise (and a stall).
            .onChange(of: selectedHostId) { _, newId in
                guard !restoring, mode == .ssh, let host = store.host(id: newId) else { return }
                listing = nil
                failure = nil
                Task { await open(host.lastPath.isEmpty ? "~" : host.lastPath) }
            }

            Button {
                if let host = selectedHost { editingHost = host }
            } label: {
                Label(L10n.t("edit"), systemImage: "pencil")
            }
            .disabled(selectedHost == nil)

            Button {
                editingHost = SSHHost()
            } label: {
                Label(L10n.t("add_host"), systemImage: "plus")
            }
            Spacer()
        }
        .controlSize(.small)
        .padding(10)
    }

    private var emptyHostState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "network")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(L10n.t("no_ssh_host"))
                .foregroundStyle(.secondary)
            Text(L10n.t("ssh_intro"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                editingHost = SSHHost()
            } label: {
                Label(L10n.t("connect_machine"), systemImage: "arrow.right.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                Task { await open("~") }
            } label: {
                Image(systemName: "house")
            }
            .help(L10n.t("go_home"))

            Button {
                Task { await open(parentPath) }
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(listing == nil || listing?.path == "/")
            .help(L10n.t("go_up"))

            TextField("/srv/projets", text: $remotePath)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await open(remotePath) } }

            if loading { ProgressView().controlSize(.small) }

            Button {
                Task { await open(remotePath) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(L10n.t("refresh"))

            Button {
                newFolderName = ""
                showNewFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .disabled(listing == nil)
            .help(L10n.t("new_folder"))
        }
        .controlSize(.small)
        .padding(10)
        .alert(L10n.t("new_folder"), isPresented: $showNewFolder) {
            TextField(L10n.t("folder_name"), text: $newFolderName)
            Button(L10n.t("create")) { Task { await createFolder() } }
            Button(L10n.t("cancel"), role: .cancel) { newFolderName = "" }
        }
    }

    private var parentPath: String {
        guard let current = listing?.path else { return "~" }
        let parent = (current as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    @ViewBuilder
    private var browser: some View {
        if let failure {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text(failure.message)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
                if failure == .hostKeyUnverified, let host = selectedHost {
                    Button(L10n.t("verify_host")) { editingHost = host }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let listing {
            List {
                Section {
                    currentFolderRow(listing)
                }
                Section(L10n.t("subfolders")) {
                    if listing.entries.isEmpty {
                        Text(L10n.t("no_subfolder"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(listing.entries) { entry in
                        Button {
                            Task { await open(join(listing.path, entry.name)) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(entry.name)
                                markers(git: entry.isGitRepo, claude: entry.hasClaudeMD)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else {
            VStack {
                Spacer()
                if loading { ProgressView() }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The folder "Use this folder" would pick — shown first so the choice is
    /// never ambiguous with whatever row happens to be highlighted.
    private func currentFolderRow(_ listing: SSHClient.Listing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("selected_folder"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(listing.path)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            markers(git: listing.isGitRepo, claude: listing.hasClaudeMD)
            Spacer()
        }
    }

    /// Badges that say "this is a project": a git repo, or a folder Claude Code
    /// already has instructions for.
    @ViewBuilder
    private func markers(git: Bool, claude: Bool) -> some View {
        HStack(spacing: 5) {
            if git {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.orange)
                    .help(L10n.t("marker_git"))
            }
            if claude {
                Image(systemName: "text.book.closed")
                    .foregroundStyle(Theme.accent)
                    .help(L10n.t("marker_claude"))
            }
        }
        .font(.caption)
    }

    private func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    // MARK: - Remote actions

    private func open(_ path: String) async {
        guard let host = selectedHost else { return }
        loading = true
        failure = nil
        remotePath = path
        switch await SSHClient.listDirectories(host, path: path) {
        case .success(let result):
            listing = result
            remotePath = result.path
        case .failure(let f):
            failure = f
            listing = nil
        }
        loading = false
    }

    private func createFolder() async {
        guard let host = selectedHost, let parent = listing?.path else { return }
        let name = newFolderName
        newFolderName = ""
        loading = true
        switch await SSHClient.makeDirectory(host, parent: parent, name: name) {
        case .success(let created):
            loading = false
            await open(created)
        case .failure(let f):
            failure = f
            loading = false
        }
    }
}

// MARK: - Connect form

/// Connect to a machine: user, address, password — then straight to its folders.
///
/// Everything else (display name, port, private key) is folded away, because the
/// common case is a box on the LAN with a password. Pressing Connect is what
/// confirms the host key, verifies `claude` is installed over there, and resolves
/// its absolute path; the machine is only saved once all three hold, so a saved
/// machine is always one that works.
private struct SSHHostEditor: View {
    let host: SSHHost
    /// nil = cancelled or deleted; a host = connected and saved.
    let onDone: (SSHHost?) -> Void

    @ObservedObject private var store = SSHHostStore.shared

    @State private var name = ""
    @State private var hostname = ""
    @State private var user = ""
    @State private var port = "22"
    @State private var identityFile = ""
    @State private var password = ""
    /// A password is already in the Keychain; the field stays empty unless the
    /// user wants to replace it.
    @State private var hasStoredPassword = false
    @State private var showAdvanced = false

    @State private var connecting = false
    @State private var errorText: String?
    @State private var fingerprints: [String] = []
    /// The exact key lines the shown fingerprints were computed from. Trusting
    /// writes these, so what the user approved is what lands in known_hosts.
    @State private var pendingHostKeys = ""
    @State private var showDeleteConfirm = false

    private var isNew: Bool { store.host(id: host.id) == nil }

    /// A password is in play when one was just typed, or one is already stored
    /// and hasn't been cleared. No toggle to forget to flip.
    private var usesPassword: Bool { !password.isEmpty || hasStoredPassword }

    private var edited: SSHHost {
        SSHHost(id: host.id,
                name: name,
                hostname: hostname,
                user: user,
                port: Int(port) ?? 22,
                identityFile: identityFile,
                usesPassword: usesPassword,
                remoteClaudePath: host.remoteClaudePath,
                lastPath: host.lastPath)
    }

    private var canConnect: Bool {
        !connecting && !hostname.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(isNew ? L10n.t("connect_machine") : L10n.t("edit_host"),
                      systemImage: "network")
                    .font(.title3.bold())
                Spacer()
            }
            .padding(14)
            Divider()

            Form {
                Section {
                    TextField(L10n.t("host_user"), text: $user, prompt: Text(NSUserName()))
                        .font(.system(.body, design: .monospaced))
                    TextField(L10n.t("host_address"), text: $hostname,
                              prompt: Text("192.168.1.42"))
                        .font(.system(.body, design: .monospaced))
                    SecureField(L10n.t("password"), text: $password,
                                prompt: Text(hasStoredPassword ? L10n.t("password_stored")
                                                               : L10n.t("password_optional")))
                        .onSubmit { Task { await connect() } }
                    Text(L10n.t("password_keychain_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    DisclosureGroup(L10n.t("advanced_options"), isExpanded: $showAdvanced) {
                        TextField(L10n.t("host_label"), text: $name, prompt: Text("Studio"))
                        TextField(L10n.t("host_port"), text: $port, prompt: Text("22"))
                        LabeledContent(L10n.t("identity_file")) {
                            HStack(spacing: 8) {
                                Text(identityFile.isEmpty ? L10n.t("identity_default") : identityFile)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Button(L10n.t("choose"), action: chooseIdentity)
                                    .controlSize(.small)
                                if !identityFile.isEmpty {
                                    Button(L10n.t("clear")) { identityFile = "" }
                                        .controlSize(.small)
                                }
                            }
                        }
                        if hasStoredPassword {
                            Button(L10n.t("forget_password")) {
                                SSHKeychain.delete(hostId: host.id)
                                hasStoredPassword = false
                                password = ""
                            }
                        }
                        Text(L10n.t("ssh_config_hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !fingerprints.isEmpty {
                    Section {
                        Label(L10n.t("hostkey_unknown"),
                              systemImage: "lock.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                        ForEach(fingerprints, id: \.self) { fp in
                            Text(fp)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        Text(L10n.t("hostkey_hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L10n.t("trust_hostkey")) { Task { await trustThenConnect() } }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                    }
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !isNew {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(L10n.t("delete"), systemImage: "trash")
                    }
                }
                Spacer()
                if connecting {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("ssh_connecting", hostname))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(L10n.t("cancel")) { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("connect")) { Task { await connect() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!canConnect)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .onAppear {
            name = host.name
            hostname = host.hostname
            user = host.user.isEmpty ? NSUserName() : host.user
            port = String(host.port)
            identityFile = host.identityFile
            hasStoredPassword = SSHKeychain.hasPassword(hostId: host.id)
            // Anything unusual is already set: show it rather than hide it.
            showAdvanced = !host.name.isEmpty || host.port != 22 || !host.identityFile.isEmpty
        }
        .confirmationDialog(L10n.t("delete_host_confirm"), isPresented: $showDeleteConfirm) {
            Button(L10n.t("delete"), role: .destructive) {
                store.delete(id: host.id)
                onDone(nil)
            }
            Button(L10n.t("cancel"), role: .cancel) {}
        }
    }

    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = L10n.t("identity_file")
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { identityFile = url.path }
    }

    /// Move the typed password into the Keychain. ssh reads it back from there
    /// at connection time, so this has to happen before anything connects — and
    /// it's why the field can be cleared straight afterwards.
    /// Returns false when the Keychain refused, so the caller can stop.
    /// Put the typed password where ssh's askpass helper will find it.
    ///
    /// It has to be stored *before* connecting — the helper reads it from the
    /// Keychain — so `staged` reports whether this attempt wrote a new one, and
    /// the caller can take it back out if ssh rejects it.
    private func stagePassword() -> (ok: Bool, staged: Bool) {
        guard !password.isEmpty else { return (true, false) }
        guard SSHKeychain.save(password: password, hostId: host.id) else {
            errorText = L10n.t("keychain_save_failed")
            return (false, false)
        }
        hasStoredPassword = true
        password = ""
        return (true, true)
    }

    /// Undo a staged password that ssh refused. Without this the rejected value
    /// stays in the Keychain while the field reads "stored" and sits empty — so
    /// the obvious retry replays the password that just failed, with nothing on
    /// screen suggesting otherwise.
    private func discardStagedPassword() {
        SSHKeychain.delete(hostId: host.id)
        hasStoredPassword = false
    }

    /// Connect, verify, save, and hand the machine back so the caller can browse
    /// it. Nothing is saved unless all of that succeeds.
    private func connect() async {
        guard canConnect else { return }
        connecting = true
        errorText = nil
        fingerprints = []
        pendingHostKeys = ""
        defer { connecting = false }
        let staging = stagePassword()
        guard staging.ok else { return }

        let candidate = edited
        // Host key first: until it's trusted, every other failure reads as a
        // generic "connection failed", which explains nothing.
        switch await SSHClient.hostKeyState(candidate) {
        case .unknown(let prints, let keys):
            fingerprints = prints
            pendingHostKeys = keys
            return
        case .unreachable:
            // Nothing answered on port 22 — say what to check rather than
            // relaying ssh-keyscan's silence.
            errorText = L10n.t("ssh_err_no_answer", candidate.detailedTarget)
            return
        case .known:
            break
        }

        switch await SSHClient.probe(candidate) {
        case .failure(let failure):
            errorText = failure.message
            // Only for a credential ssh actually refused, and only one this
            // attempt wrote: a connection that merely timed out says nothing
            // about a password that may have been working for months.
            if case .authenticationFailed = failure, staging.staged {
                discardStagedPassword()
            }
        case .success(let probe):
            guard probe.hasClaude else {
                errorText = SSHClient.Failure.claudeMissing.message
                return
            }
            var saved = candidate
            saved.remoteClaudePath = probe.claudePath
            // Open on the remote home the probe just reported, unless this
            // machine already has a folder we were using.
            if saved.lastPath.isEmpty { saved.lastPath = probe.home }
            store.save(saved)
            onDone(saved)
        }
    }

    private func trustThenConnect() async {
        connecting = true
        errorText = nil
        switch await SSHClient.acceptHostKey(edited, keys: pendingHostKeys) {
        case .success:
            fingerprints = []
            pendingHostKeys = ""
            connecting = false
            await connect()
        case .failure(let failure):
            errorText = failure.message
            connecting = false
        }
    }
}
