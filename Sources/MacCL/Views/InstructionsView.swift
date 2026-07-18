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

    private var selectedFile: InstructionFile? { store.files.first { $0.id == selection } }

    private var projectFileURL: URL {
        URL(fileURLWithPath: AppSettings.shared.workingDirectory)
            .appendingPathComponent("CLAUDE.md")
    }

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
            projectText = (try? String(contentsOf: projectFileURL, encoding: .utf8)) ?? ""
        }
    }

    /// Editor for the working folder's CLAUDE.md — Claude Code reads it natively.
    private var projectEditor: some View {
        VStack(spacing: 0) {
            TextEditor(text: $projectText)
                .font(.system(.body, design: .monospaced))
                .padding(6)
            Divider()
            HStack(spacing: 10) {
                Text(projectFileURL.path)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(L10n.t("project_hint"))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button(L10n.t("save")) {
                    try? projectText.write(to: projectFileURL, atomically: true, encoding: .utf8)
                }
                Button(L10n.t("close")) {
                    try? projectText.write(to: projectFileURL, atomically: true, encoding: .utf8)
                    dismiss()
                }
                .tint(Theme.accent)
            }
            .padding(10)
        }
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
