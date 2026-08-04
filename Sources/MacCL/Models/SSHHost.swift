import Foundation
import Combine

/// A saved SSH machine that can host a conversation's working directory.
///
/// The password is deliberately NOT a property: it lives in the macOS Keychain,
/// keyed by `id` (see `SSHKeychain`). `usesPassword` only records that one is
/// expected, so the launcher knows to hand ssh an askpass helper rather than
/// leave it waiting on a prompt no GUI can answer.
struct SSHHost: Identifiable, Codable, Hashable {
    let id: String
    /// Display label. Empty falls back to `target`.
    var name: String
    var hostname: String
    var user: String
    var port: Int
    /// Explicit private key. Empty = let ssh decide (agent, ~/.ssh/config).
    var identityFile: String
    /// A password is expected and stored in the Keychain under `id`.
    var usesPassword: Bool
    /// Absolute path of `claude` on that machine, as found by the probe.
    /// Empty = resolve it from the remote PATH at launch.
    var remoteClaudePath: String
    /// Last directory browsed on this host — where the explorer opens next time.
    var lastPath: String

    init(id: String = UUID().uuidString,
         name: String = "",
         hostname: String = "",
         user: String = NSUserName(),
         port: Int = 22,
         identityFile: String = "",
         usesPassword: Bool = false,
         remoteClaudePath: String = "",
         lastPath: String = "") {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespaces)
        self.hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = (1...65535).contains(port) ? port : 22
        self.identityFile = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        self.usesPassword = usesPassword
        self.remoteClaudePath = remoteClaudePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lastPath = lastPath
    }

    // MARK: - Presentation

    /// `user@host`, or just the host when no user is set (~/.ssh/config supplies it).
    var target: String {
        user.isEmpty ? hostname : "\(user)@\(hostname)"
    }

    /// What the UI shows in a button or a list row.
    var label: String {
        name.isEmpty ? target : name
    }

    /// `user@host:port`, port omitted when standard.
    var detailedTarget: String {
        port == 22 ? target : "\(target):\(port)"
    }

    /// The minimum needed to attempt a connection.
    var isUsable: Bool { !hostname.isEmpty }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, user, port, identityFile, usesPassword,
             remoteClaudePath, lastPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Keep the persisted id: it's the Keychain account key for the password.
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        hostname = try c.decode(String.self, forKey: .hostname)
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        let rawPort = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        port = (1...65535).contains(rawPort) ? rawPort : 22
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        usesPassword = try c.decodeIfPresent(Bool.self, forKey: .usesPassword) ?? false
        remoteClaudePath = try c.decodeIfPresent(String.self, forKey: .remoteClaudePath) ?? ""
        lastPath = try c.decodeIfPresent(String.self, forKey: .lastPath) ?? ""
    }

    // MARK: - Array persistence (same shape as StandbyServer)

    static func encodeArray(_ array: [SSHHost]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(array))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    static func decodeArray(from raw: String) -> [SSHHost] {
        guard let data = raw.data(using: .utf8),
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return (try? JSONDecoder().decode([SSHHost].self, from: data)) ?? []
    }
}

/// Where a conversation's files live: this Mac, or a directory on an SSH host.
///
/// `hostId` empty means local — the same shape the app had before SSH existed,
/// so an old conversation with no recorded host simply reads as local.
struct WorkLocation: Equatable, Hashable {
    var hostId: String
    var path: String

    var isLocal: Bool { hostId.isEmpty }

    static func local(_ path: String) -> WorkLocation { WorkLocation(hostId: "", path: path) }
}

/// The saved SSH hosts, backed by `AppSettings.sshHostsRaw`.
///
/// A separate observable object so the explorer and the host editor can react to
/// edits without every view that touches settings redrawing.
@MainActor
final class SSHHostStore: ObservableObject {
    static let shared = SSHHostStore()

    @Published private(set) var hosts: [SSHHost] = []

    private let settings = AppSettings.shared

    private init() {
        hosts = SSHHost.decodeArray(from: settings.sshHostsRaw)
    }

    func host(id: String) -> SSHHost? {
        guard !id.isEmpty else { return nil }
        return hosts.first { $0.id == id }
    }

    /// Insert or update by id.
    func save(_ host: SSHHost) {
        var list = hosts
        if let idx = list.firstIndex(where: { $0.id == host.id }) {
            list[idx] = host
        } else {
            list.append(host)
        }
        persist(list)
    }

    /// Remove the host and the password it may have left in the Keychain.
    func delete(id: String) {
        SSHKeychain.delete(hostId: id)
        persist(hosts.filter { $0.id != id })
    }

    /// Remember where the explorer last stood on this host, without disturbing
    /// anything else the user may have edited.
    func rememberPath(_ path: String, forHost id: String) {
        guard var h = host(id: id), h.lastPath != path else { return }
        h.lastPath = path
        save(h)
    }

    /// Record the absolute `claude` path the probe found, so the launch command
    /// doesn't depend on whatever PATH a non-interactive ssh session inherits.
    func rememberClaudePath(_ path: String, forHost id: String) {
        guard var h = host(id: id), h.remoteClaudePath != path else { return }
        h.remoteClaudePath = path
        save(h)
    }

    private func persist(_ list: [SSHHost]) {
        hosts = list
        settings.sshHostsRaw = SSHHost.encodeArray(list)
    }
}
