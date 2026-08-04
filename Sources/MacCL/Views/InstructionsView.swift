import SwiftUI
import AppKit

/// Library manager for coding-instruction `.md` files: list, toggle, edit.
struct InstructionsView: View {
    @ObservedObject private var store = InstructionsStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selection: InstructionFile.ID?
    @State private var editorText: String = ""
    @State private var showNew = false
    @State private var newName = ""
    @State private var tab = 0                 // 0 = library, 1 = project CLAUDE.md
    @State private var projectText: String = ""
    /// Remote CLAUDE.md state — loading, and whatever went wrong.
    @State private var projectLoading = false
    @State private var projectError: String?
    /// The file never loaded, so the editor holds nothing that may be written
    /// back: saving would replace a file we failed to read with an empty one.
    @State private var projectLoadFailed = false

    private var selectedFile: InstructionFile? { store.files.first { $0.id == selection } }

    /// The machine the working folder lives on — nil when it's this Mac.
    private var workHost: SSHHost? {
        SSHHostStore.shared.host(id: AppSettings.shared.workLocationHostId)
    }

    /// Path of the working folder's CLAUDE.md, on whichever machine that is.
    private var projectFilePath: String {
        let dir = AppSettings.shared.workingDirectory
        return dir.hasSuffix("/") ? dir + "CLAUDE.md" : dir + "/CLAUDE.md"
    }

    private var projectFileURL: URL { URL(fileURLWithPath: projectFilePath) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(L10n.t("library")).tag(0)
                Text(L10n.t("project_md")).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()

            if tab == 0 {
                HStack(spacing: 0) {
                    fileList
                    Divider()
                    editor
                }
                Divider()
                bottomBar
            } else {
                projectEditor
            }
        }
        .frame(width: 760, height: 500)
        .onAppear {
            if selection == nil { selection = store.files.first?.id }
            editorText = selectedFile?.read() ?? ""
            Task { await loadProjectFile() }
        }
    }

    /// Editor for the working folder's CLAUDE.md — Claude Code reads it natively.
    /// When the folder is on an SSH machine, so is the file: it's fetched and
    /// written back over the same connection the agent runs on, because editing
    /// a local copy of a file the agent never sees would be worse than useless.
    private var projectEditor: some View {
        VStack(spacing: 0) {
            ZStack {
                TextEditor(text: $projectText)
                    .font(.system(.body, design: .monospaced))
                    .padding(6)
                    .disabled(projectLoading || projectLoadFailed)
                if projectLoading { ProgressView() }
            }
            if let projectError {
                Label(projectError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: 10) {
                if let host = workHost {
                    Label(host.label, systemImage: "network")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                Text(projectFilePath)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(L10n.t("project_hint"))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button(L10n.t("save")) { Task { await saveProjectFile() } }
                    .disabled(projectLoading || projectLoadFailed)
                Button(L10n.t("close")) {
                    Task {
                        await saveProjectFile()
                        dismiss()
                    }
                }
                .tint(Theme.accent)
            }
            .padding(10)
        }
    }

    private func loadProjectFile() async {
        projectError = nil
        projectLoadFailed = false
        guard let host = workHost else {
            projectText = (try? String(contentsOf: projectFileURL, encoding: .utf8)) ?? ""
            return
        }
        projectLoading = true
        switch await SSHClient.readFile(host, path: projectFilePath) {
        case .success(let text): projectText = text
        case .failure(let f):
            projectText = ""
            projectError = f.message
            projectLoadFailed = true
        }
        projectLoading = false
    }

    /// Saving must not fail in silence: an unwritable remote file used to look
    /// exactly like a successful save.
    private func saveProjectFile() async {
        guard !projectLoadFailed, !projectLoading else { return }
        projectError = nil
        guard let host = workHost else {
            do {
                try projectText.write(to: projectFileURL, atomically: true, encoding: .utf8)
            } catch {
                projectError = error.localizedDescription
            }
            return
        }
        projectLoading = true
        if case .failure(let f) = await SSHClient.writeFile(host, path: projectFilePath,
                                                            content: projectText) {
            projectError = f.message
        }
        projectLoading = false
    }

    private var fileList: some View {
        List(selection: $selection) {
            Section(L10n.t("instructions")) {
                ForEach(store.files) { file in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { store.isEnabled(file) },
                            set: { store.setEnabled(file, $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        Text(file.title)
                            .lineLimit(1)
                    }
                    .tag(file.id)
                }
            }
        }
        .frame(width: 240)
        .onChange(of: selection) { oldID, newID in
            if let old = store.files.first(where: { $0.id == oldID }) {
                store.save(old, content: editorText)
            }
            editorText = store.files.first(where: { $0.id == newID })?.read() ?? ""
        }
    }

    private var editor: some View {
        Group {
            if selectedFile != nil {
                TextEditor(text: $editorText)
                    .font(.system(.body, design: .monospaced))
                    .padding(6)
            } else {
                Text(L10n.t("select_instruction"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { showNew = true } label: { Label(L10n.t("new"), systemImage: "plus") }
            Button(role: .destructive) {
                if let f = selectedFile {
                    store.delete(f)
                    selection = store.files.first?.id
                    editorText = selectedFile?.read() ?? ""
                }
            } label: { Label(L10n.t("delete"), systemImage: "trash") }
            .disabled(selectedFile == nil)
            Button { NSWorkspace.shared.open(AppPaths.instructions) } label: {
                Label(L10n.t("folder"), systemImage: "folder")
            }
            Spacer()
            Text("\(store.activeCount) \(L10n.t("actives"))")
                .foregroundStyle(.secondary)
            Button(L10n.t("save")) { if let f = selectedFile { store.save(f, content: editorText) } }
                .keyboardShortcut("s")
            Button(L10n.t("close")) {
                if let f = selectedFile { store.save(f, content: editorText) }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .tint(Theme.accent)
        }
        .padding(10)
        .alert(L10n.t("new_instruction"), isPresented: $showNew) {
            TextField(L10n.t("file_name"), text: $newName)
            Button(L10n.t("new")) {
                if let f = store.create(named: newName) {
                    selection = f.id
                    editorText = f.read()
                }
                newName = ""
            }
            Button(L10n.t("cancel"), role: .cancel) { newName = "" }
        } message: {
            Text(L10n.t("instr_msg"))
        }
    }
}
