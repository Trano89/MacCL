import Foundation
import Combine

/// Read-only view of `<workingDirectory>/.claude/agents/*.md`.
///
/// The conversation's own sub-agent model setting is what MacCL offers, because
/// it covers every agent Claude Code spawns. These files are the CLI's own
/// mechanism and stay supported for anyone who hand-writes one: the only thing
/// read here is which machines they name, so `AgentRouter` knows to open a
/// route for them. Nothing in the app writes them.
@MainActor
final class AgentStore: ObservableObject {
    static let shared = AgentStore()

    @Published private(set) var agents: [AgentDefinition] = []
    /// Non-nil when the last listing failed — an unreachable machine must not
    /// read as "this project has no agents".
    @Published private(set) var lastError: String?

    /// The location the current list came from, so `loadIfNeeded` can tell a
    /// cache hit from a different working folder.
    private var location: WorkLocation?

    private init() {}

    /// `.claude/agents` under a working directory.
    static func directory(for workingDirectory: String) -> String {
        (workingDirectory as NSString).appendingPathComponent(".claude/agents")
    }

    // MARK: - Loading

    func load(location: WorkLocation) async {
        self.location = location
        lastError = nil

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

    /// Load only if this location hasn't been listed yet. Called on the send
    /// path, where a remote listing costs an SSH round trip per turn — and the
    /// list has already been read when the working folder was chosen.
    func loadIfNeeded(location: WorkLocation) async {
        guard self.location != location else { return }
        await load(location: location)
    }

    // MARK: - Routing

    /// Server names referenced by the loaded agents, i.e. the machines a turn
    /// may need to reach beyond the conversation's own server. Empty means no
    /// router is needed at all.
    var referencedServerNames: Set<String> {
        Set(agents.map(\.serverName).filter { !$0.isEmpty })
    }
}
