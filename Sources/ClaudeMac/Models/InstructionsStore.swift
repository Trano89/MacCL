import Foundation
import Combine

/// One markdown instruction file in the library.
struct InstructionFile: Identifiable, Hashable {
    var id: String { filename }
    let filename: String
    let url: URL

    var title: String {
        filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
    }

    func read() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}

/// A library of coding-instruction `.md` files. Enabled files are concatenated
/// and appended to Claude's system prompt (`--append-system-prompt`), which is
/// the Claude-Code-native way to steer the agent without replacing its prompt.
@MainActor
final class InstructionsStore: ObservableObject {
    static let shared = InstructionsStore()

    @Published private(set) var files: [InstructionFile] = []
    @Published var enabled: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabled), forKey: "enabledInstructions") }
    }

    private init() {
        enabled = Set(UserDefaults.standard.stringArray(forKey: "enabledInstructions") ?? [])
        reload()
        if files.isEmpty { seedDefault() }
    }

    func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: AppPaths.instructions,
                                                includingPropertiesForKeys: nil)) ?? []
        files = urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { InstructionFile(filename: $0.lastPathComponent, url: $0) }
            .sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
    }

    /// The combined instruction text to append to the system prompt.
    func combinedPrompt() -> String {
        let parts = files
            .filter { enabled.contains($0.filename) }
            .map { $0.read().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: "\n\n---\n\n")
    }

    var activeCount: Int { enabled.intersection(Set(files.map(\.filename))).count }

    // MARK: - Mutations

    @discardableResult
    func create(named rawName: String) -> InstructionFile? {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "instructions" }
        if !name.hasSuffix(".md") { name += ".md" }
        let url = AppPaths.instructions.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "# \(name.dropLast(3))\n\n".write(to: url, atomically: true, encoding: .utf8)
        }
        reload()
        let file = files.first { $0.filename == name }
        if let file { enabled.insert(file.filename) }
        return file
    }

    func save(_ file: InstructionFile, content: String) {
        try? content.write(to: file.url, atomically: true, encoding: .utf8)
    }

    func delete(_ file: InstructionFile) {
        try? FileManager.default.removeItem(at: file.url)
        enabled.remove(file.filename)
        reload()
    }

    func setEnabled(_ file: InstructionFile, _ on: Bool) {
        if on { enabled.insert(file.filename) } else { enabled.remove(file.filename) }
    }

    func isEnabled(_ file: InstructionFile) -> Bool { enabled.contains(file.filename) }

    private func seedDefault() {
        let starter = """
        # Directives de codage

        - Écris du code clair et idiomatique, cohérent avec le style du fichier environnant.
        - Préfère des changements minimaux et ciblés ; ne réécris pas ce qui fonctionne déjà.
        - Ajoute des commentaires uniquement quand ils clarifient une intention non évidente.
        - Gère explicitement les cas limites et les erreurs.
        - Après une modification, vérifie que le projet compile et que les tests passent.
        - N'ajoute pas de dépendances sans nécessité ; réutilise l'existant.
        - Explique brièvement les décisions non triviales.
        """
        let url = AppPaths.instructions.appendingPathComponent("directives-codage.md")
        try? starter.write(to: url, atomically: true, encoding: .utf8)
        reload()
        enabled.insert("directives-codage.md")
    }
}
