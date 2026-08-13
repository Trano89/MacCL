import Foundation
import Combine

/// The sub-agents of one working directory, read from and written to
/// `<workingDirectory>/.claude/agents/*.md`.
///
/// That location is not a choice: it is where the `claude` CLI looks. Which
/// means the files must land on the machine the CLI *runs on* — the remote one
/// when the conversation works over SSH — so every operation here takes the
/// work location, not just a path.
@MainActor
final class AgentStore: ObservableObject {
    static let shared = AgentStore()

    @Published private(set) var agents: [AgentDefinition] = []
    /// Non-nil when the last load or save failed — surfaced by the library view
    /// instead of leaving an empty list that looks like "no agents".
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false

    /// The location the currently-listed agents came from, so a reload after an
    /// edit goes back to the same machine.
    private var location: WorkLocation?

    private init() {}

    /// `.claude/agents` under a working directory.
    static func directory(for workingDirectory: String) -> String {
        (workingDirectory as NSString).appendingPathComponent(".claude/agents")
    }

    // MARK: - Loading

    func load(location: WorkLocation) async {
        self.location = location
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let dir = Self.directory(for: location.path)
        if let host = SSHHostStore.shared.host(id: location.hostId) {
            switch await SSHClient.listFiles(host, directory: dir, suffix: ".md") {
            case .failure(let f):
                lastError = f.message
                agents = []
            case .success(let names):
                var loaded: [AgentDefinition] = []
                for name in names {
                    let path = (dir as NSString).appendingPathComponent(name)
                    if case .success(let text) = await SSHClient.readFile(host, path: path),
                       let def = AgentDefinition.parse(filename: name, contents: text) {
                        loaded.append(def)
                    }
                }
                agents = loaded.sorted { $0.name < $1.name }
            }
            return
        }

        // Local: a missing directory is simply "no agents yet".
        let url = URL(fileURLWithPath: dir)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil)) ?? []
        agents = urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { u in
                guard let text = try? String(contentsOf: u, encoding: .utf8) else { return nil }
                return AgentDefinition.parse(filename: u.lastPathComponent, contents: text)
            }
            .sorted { $0.name < $1.name }
    }

    /// Reload from wherever the last load came from (after a save or delete).
    func reload() async {
        guard let location else { return }
        await load(location: location)
    }

    /// Load only if this location hasn't been listed yet. Called on the send
    /// path, where a remote listing costs an SSH round trip per turn — and the
    /// list has already been read when the working folder was chosen.
    func loadIfNeeded(location: WorkLocation) async {
        guard self.location != location else { return }
        await load(location: location)
    }

    // MARK: - Mutations

    /// Write one agent. Returns nil on success, else a message to show.
    @discardableResult
    func save(_ agent: AgentDefinition, location: WorkLocation) async -> String? {
        self.location = location
        let dir = Self.directory(for: location.path)
        let path = (dir as NSString).appendingPathComponent(agent.filename)
        let contents = agent.fileContents()

        if let host = SSHHostStore.shared.host(id: location.hostId) {
            switch await SSHClient.writeFileCreatingParents(host, path: path, content: contents) {
            case .failure(let f):
                lastError = f.message
                return f.message
            case .success:
                break
            }
        } else {
            let url = URL(fileURLWithPath: path)
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                lastError = error.localizedDescription
                return error.localizedDescription
            }
        }
        AppLog.info("agents", "saved \(agent.filename) model=\(agent.modelField) at \(location.hostId.isEmpty ? "local" : location.hostId)")
        await reload()
        return nil
    }

    @discardableResult
    func delete(_ agent: AgentDefinition, location: WorkLocation) async -> String? {
        self.location = location
        let dir = Self.directory(for: location.path)
        let path = (dir as NSString).appendingPathComponent(agent.filename)

        if let host = SSHHostStore.shared.host(id: location.hostId) {
            if case .failure(let f) = await SSHClient.deleteFile(host, path: path) {
                lastError = f.message
                return f.message
            }
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
        await reload()
        return nil
    }

    // MARK: - Routing

    /// Server names referenced by the loaded agents, i.e. the machines a turn
    /// may need to reach beyond the conversation's own server. Empty means no
    /// router is needed at all.
    var referencedServerNames: Set<String> {
        Set(agents.map(\.serverName).filter { !$0.isEmpty })
    }

    /// Agents whose `@server` suffix names a machine that isn't in the standby
    /// list — those would be dispatched nowhere, so the UI must say so.
    func unresolvedServerNames(known: [StandbyServer]) -> [String] {
        let names = Set(known.map(\.name))
        return referencedServerNames.subtracting(names).sorted()
    }
}
