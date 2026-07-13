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

    private var selectedFile: InstructionFile? { store.files.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                fileList
                Divider()
                editor
            }
            Divider()
            bottomBar
        }
        .frame(width: 760, height: 480)
        .onAppear {
            if selection == nil { selection = store.files.first?.id }
            editorText = selectedFile?.read() ?? ""
        }
    }

    private var fileList: some View {
        List(selection: $selection) {
            Section("Instructions") {
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
                Text("Sélectionnez une instruction, ou créez-en une.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { showNew = true } label: { Label("Nouveau", systemImage: "plus") }
            Button(role: .destructive) {
                if let f = selectedFile {
                    store.delete(f)
                    selection = store.files.first?.id
                    editorText = selectedFile?.read() ?? ""
                }
            } label: { Label("Supprimer", systemImage: "trash") }
            .disabled(selectedFile == nil)
            Button { NSWorkspace.shared.open(AppPaths.instructions) } label: {
                Label("Dossier", systemImage: "folder")
            }
            Spacer()
            Text("\(store.activeCount) active(s) · injectées dans le prompt")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Enregistrer") { if let f = selectedFile { store.save(f, content: editorText) } }
                .keyboardShortcut("s")
            Button("Fermer") {
                if let f = selectedFile { store.save(f, content: editorText) }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .tint(Theme.accent)
        }
        .padding(10)
        .alert("Nouvelle instruction", isPresented: $showNew) {
            TextField("nom du fichier", text: $newName)
            Button("Créer") {
                if let f = store.create(named: newName) {
                    selection = f.id
                    editorText = f.read()
                }
                newName = ""
            }
            Button("Annuler", role: .cancel) { newName = "" }
        } message: {
            Text("Un fichier .md sera créé dans la bibliothèque et activé.")
        }
    }
}
