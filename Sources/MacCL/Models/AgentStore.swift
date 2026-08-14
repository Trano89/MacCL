import Foundation

/// Which machines the working folder's `.claude/agents/*.md` files name.
///
/// That is the whole job. Claude Code reads those files itself for everything
/// that matters; the one thing it cannot do is open a network route to another
/// machine, so MacCL reads only the machine names and hands them to
/// `AgentRouter`. Nothing here writes, and no view observes it — the sub-agent
/// model the app actually offers is a setting on the conversation.
@MainActor
final class AgentStore {
    static let shared = AgentStore()

    /// Machines referenced by the current folder's agent files. Empty — the
    /// normal case — means no router is needed on their account.
    private(set) var referencedServerNames: Set<String> = []

    /// The location the current list came from, so `loadIfNeeded` can tell a
    /// cache hit from a different working folder.
    private var location: WorkLocation?

    private init() {}

    /// `.claude/agents` under a working directory.
    private static func directory(for workingDirectory: String) -> String {
        (workingDirectory as NSString).appendingPathComponent(".claude/agents")
    }

    /// Read only when this location hasn't been listed yet. This runs on the
    /// send path, where a remote listing costs an SSH round trip per turn.
    func loadIfNeeded(location: WorkLocation) async {
        guard self.location != location else { return }
        await load(location: location)
    }

    func load(location: WorkLocation) async {
        self.location = location
        let dir = Self.directory(for: location.path)

        if let host = SSHHostStore.shared.host(id: location.hostId) {
            switch await SSHClient.listFiles(host, directory: dir, suffix: ".md") {
            case .failure(let failure):
                // An unreachable machine must not read as "no routed agents" in
                // silence: that would send a routed sub-agent to the
                // conversation's server under a model it doesn't have.
                AppLog.warn("agents", "could not list \(dir) on \(host.label): \(failure.message)")
                referencedServerNames = []
            case .success(let names):
                var found: Set<String> = []
                for name in names {
                    let path = (dir as NSString).appendingPathComponent(name)
                    if case .success(let text) = await SSHClient.readFile(host, path: path),
                       let machine = AgentDefinition.routedMachine(inFileContents: text) {
                        found.insert(machine)
                    }
                }
                referencedServerNames = found
            }
            return
        }

        // Local: a missing directory simply names no machines.
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
        referencedServerNames = Set(urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return AgentDefinition.routedMachine(inFileContents: text)
            })
    }
}
