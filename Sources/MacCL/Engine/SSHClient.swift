import Foundation

/// Everything MacCL does over SSH: probing a machine, browsing its directories,
/// creating one, reading and writing a file, and building the argument list that
/// runs `claude` there.
///
/// It shells out to the system `ssh` rather than embedding a library, which buys
/// three things for free: `~/.ssh/config` aliases, the running ssh-agent, and the
/// user's existing keys.
///
/// Passwords use OpenSSH's own `SSH_ASKPASS` mechanism — the answer to "a GUI has
/// no terminal for ssh to prompt on". `SSH_ASKPASS_REQUIRE=force` (OpenSSH 8.4+;
/// macOS ships 10.x) makes ssh call our helper instead of a tty, so nothing extra
/// has to be installed. The secret reaches the helper through the environment,
/// never argv: argv is readable by any process on the machine, environment is not.
///
/// Host keys are handled explicitly: every connection runs with
/// `StrictHostKeyChecking=yes`, so an unknown or changed key fails loudly instead
/// of being accepted behind the user's back. `fingerprints(for:)` and
/// `acceptHostKey(for:)` implement the one-time confirmation the UI presents.
enum SSHClient {

    // MARK: - Failures

    /// `LocalizedError` matters here: `ClaudeSession.send` restarts a dead
    /// session off the UI path and reports `error.localizedDescription`, which
    /// for a bare enum is the useless "operation couldn't be completed". The
    /// localized, user-facing wording is `message` below; this is the technical
    /// fallback, in the same register as the raw ssh output shown beside it.
    enum Failure: Error, Equatable, LocalizedError {
        /// The system has no `ssh` (effectively impossible on macOS, but the
        /// launcher must not force-unwrap its way into a crash).
        case sshMissing
        /// The askpass helper couldn't be written to Application Support.
        case askpassUnavailable
        /// Password auth is configured but the Keychain holds nothing.
        case passwordMissing
        /// The host key is unknown or has changed — never auto-accepted.
        case hostKeyUnverified
        case authenticationFailed(String)
        case connectionFailed(String)
        case timedOut
        case noSuchDirectory(String)
        case notADirectory(String)
        case permissionDenied(String)
        case invalidName
        case alreadyExists(String)
        /// The machine answered the connection but offered no host key to trust.
        case noHostKey
        case remoteError(String)
        /// The remote machine has no `claude` on it.
        case claudeMissing
        case hostNotConfigured

        var errorDescription: String? {
            switch self {
            case .sshMissing: return "ssh not found"
            case .askpassUnavailable: return "could not install the askpass helper"
            case .passwordMissing: return "no password in Keychain"
            case .hostKeyUnverified: return "host key verification failed"
            case .authenticationFailed(let d): return d.isEmpty ? "authentication failed" : d
            case .connectionFailed(let d): return d.isEmpty ? "connection failed" : d
            case .timedOut: return "timed out"
            case .noSuchDirectory(let p): return "no such directory: \(p)"
            case .notADirectory(let p): return "not a directory: \(p)"
            case .permissionDenied(let p): return "permission denied: \(p)"
            case .invalidName: return "invalid name"
            case .alreadyExists(let n): return "\(n) already exists"
            case .noHostKey: return "no host key offered"
            case .remoteError(let d): return d
            case .claudeMissing: return "claude not installed on the remote host"
            case .hostNotConfigured: return "host not configured"
            }
        }

        /// The wording shown to the user, in the app's language.
        @MainActor
        var message: String {
            switch self {
            case .sshMissing: return L10n.t("ssh_err_no_ssh")
            case .askpassUnavailable: return L10n.t("ssh_err_askpass")
            case .passwordMissing: return L10n.t("ssh_err_no_password")
            case .hostKeyUnverified: return L10n.t("ssh_err_hostkey")
            case .authenticationFailed(let d):
                return d.isEmpty ? L10n.t("ssh_err_auth") : L10n.t("ssh_err_auth") + " — " + d
            case .connectionFailed(let d):
                return d.isEmpty ? L10n.t("ssh_err_connect") : L10n.t("ssh_err_connect") + " — " + d
            case .timedOut: return L10n.t("ssh_err_timeout")
            case .noSuchDirectory(let p): return L10n.t("ssh_err_nodir", p)
            case .notADirectory(let p): return L10n.t("ssh_err_notdir", p)
            case .permissionDenied(let p): return L10n.t("ssh_err_denied", p)
            case .invalidName: return L10n.t("ssh_err_badname")
            case .alreadyExists(let n): return L10n.t("ssh_err_exists", n)
            case .noHostKey: return L10n.t("ssh_err_nokey")
            case .remoteError(let d): return d
            case .claudeMissing: return L10n.t("ssh_err_no_claude")
            case .hostNotConfigured: return L10n.t("ssh_err_no_host")
            }
        }
    }

    // MARK: - Results

    /// One subdirectory as the explorer shows it.
    struct RemoteEntry: Identifiable, Hashable, Sendable {
        let name: String
        let isGitRepo: Bool
        let hasClaudeMD: Bool
        var id: String { name }
    }

    struct Listing: Sendable {
        /// The canonical path the remote resolved to (symlinks and `~` expanded).
        var path: String
        var entries: [RemoteEntry]
        var isGitRepo: Bool
        var hasClaudeMD: Bool
    }

    struct Probe: Sendable {
        var home: String
        var uname: String
        /// Absolute path of `claude` on that machine, "" when it has none.
        var claudePath: String
        /// The version string it reports, nil when it couldn't be run.
        var claudeVersion: String?
        var hasClaude: Bool { !claudePath.isEmpty }
    }

    // MARK: - Shell quoting

    /// Wrap a string so a POSIX shell sees it as one literal argument.
    ///
    /// Every path, name and environment value crosses two shells (the remote
    /// login shell that ssh hands the command to, then the `sh -lc` inside it),
    /// so this is the single point where injection is stopped. Single quotes
    /// protect everything; an embedded quote is closed, escaped and reopened.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Binaries

    private static var sshPath: String? { BinaryLocator.find("ssh") }

    /// The helper ssh calls when it needs a password. It carries no secret of its
    /// own — it just echoes what MacCL put in the child's environment — so it can
    /// live on disk permanently. 0700 all the way down so no other account can
    /// substitute a program that ssh would then run on our behalf.
    private static func askpassHelper() -> String? {
        let dir = AppPaths.support.appendingPathComponent("bin", isDirectory: true)
        let script = dir.appendingPathComponent("maccl-askpass")
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: script.path) { return script.path }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let body = "#!/bin/sh\nprintf '%s\\n' \"$MACCL_SSH_PASSWORD\"\n"
            try body.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            AppLog.warn("ssh", "askpass helper install failed: \(error.localizedDescription)")
            return nil
        }
        return fm.isExecutableFile(atPath: script.path) ? script.path : nil
    }

    // MARK: - Argument building

    /// A ready-to-spawn command: what to execute, with which arguments and
    /// environment. Built here so the browsing calls and the real `claude`
    /// session can never drift apart in how they connect.
    struct Launch: Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    /// ssh options shared by every connection MacCL makes.
    ///
    /// `StrictHostKeyChecking=yes` is the important one: MacCL asks the user to
    /// confirm a fingerprint once (see `fingerprints(for:)`) instead of letting
    /// ssh trust whatever answers on first contact.
    private static func baseOptions(for host: SSHHost, connectTimeout: Int) -> [String] {
        var opts = [
            "-T",                                   // no pty: raw stdin/stdout
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=\(connectTimeout)",
            // Load-bearing with askpass: on a wrong password ssh would otherwise
            // re-invoke the helper, get the same wrong answer, and keep going —
            // measured as a hang with no way for the user to cancel.
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "LogLevel=ERROR",
        ]
        if host.port != 22 { opts += ["-p", String(host.port)] }
        if !host.identityFile.isEmpty {
            opts += ["-i", (host.identityFile as NSString).expandingTildeInPath,
                     "-o", "IdentitiesOnly=yes"]
        }
        if !host.usesPassword {
            // Fail instead of hanging on a prompt no window can answer.
            opts += ["-o", "BatchMode=yes"]
        }
        return opts
    }

    /// Build the launch for an arbitrary remote command.
    static func launch(for host: SSHHost,
                       remoteCommand: String,
                       extraOptions: [String] = [],
                       connectTimeout: Int = 10) -> Result<Launch, Failure> {
        guard host.isUsable else { return .failure(.hostNotConfigured) }
        guard let ssh = sshPath else { return .failure(.sshMissing) }

        let args = baseOptions(for: host, connectTimeout: connectTimeout)
            + extraOptions + [host.target, remoteCommand]

        guard host.usesPassword else {
            return .success(Launch(executable: ssh, arguments: args, environment: [:]))
        }
        guard let password = SSHKeychain.load(hostId: host.id), !password.isEmpty else {
            return .failure(.passwordMissing)
        }
        guard let askpass = askpassHelper() else { return .failure(.askpassUnavailable) }
        return .success(Launch(executable: ssh, arguments: args, environment: [
            "SSH_ASKPASS": askpass,
            // Without `force`, ssh only consults the helper when it has no tty —
            // and would silently fall back to prompting into the void.
            "SSH_ASKPASS_REQUIRE": "force",
            "MACCL_SSH_PASSWORD": password,
        ]))
    }

    // MARK: - Remote command wrapper

    /// Wrap a script so it runs in a login shell with the PATH MacCL expects,
    /// mirroring what `BinaryLocator` does for local spawns. Without this, a
    /// non-interactive ssh session gets a bare PATH and can't find node, git or
    /// anything installed by a version manager.
    static func loginShellCommand(_ script: String, arguments: [String] = []) -> String {
        let full = """
        PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$PATH"
        export PATH
        \(script)
        """
        let quotedArgs = arguments.map { " " + shellQuote($0) }.joined()
        return "sh -lc " + shellQuote(full) + " maccl" + quotedArgs
    }

    // MARK: - Process execution

    private struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    /// Thread-safe accumulator — the two pipes are drained concurrently so a
    /// large listing can't deadlock on a full pipe buffer.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    private static func execute(_ launch: Launch,
                                stdin: Data? = nil,
                                timeout: TimeInterval) -> Output {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch.executable)
        proc.arguments = launch.arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BinaryLocator.mergedPATH(base: env["PATH"])
        for (k, v) in launch.environment { env[k] = v }
        proc.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return Output(status: -1, stdout: "",
                          stderr: error.localizedDescription, timedOut: false)
        }

        if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
        try? inPipe.fileHandleForWriting.close()

        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "maccl.ssh.read", attributes: .concurrent)
        queue.async(group: group) { outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile()) }
        queue.async(group: group) { errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile()) }

        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            proc.terminate()
            // Give it a moment to die politely, then stop waiting on the pipes:
            // a wedged ssh must not hold this thread forever.
            if group.wait(timeout: .now() + 2) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                _ = group.wait(timeout: .now() + 2)
            }
        }
        proc.waitUntilExit()

        return Output(status: proc.terminationStatus,
                      stdout: String(decoding: outBox.value, as: UTF8.self),
                      stderr: String(decoding: errBox.value, as: UTF8.self),
                      timedOut: timedOut)
    }

    /// Run a remote command and hand back its stdout, or a typed failure.
    private static func run(_ host: SSHHost,
                            command: String,
                            stdin: Data? = nil,
                            timeout: TimeInterval = 20) async -> Result<Output, Failure> {
        switch launch(for: host, remoteCommand: command) {
        case .failure(let f):
            return .failure(f)
        case .success(let l):
            let out = await Task.detached(priority: .userInitiated) {
                execute(l, stdin: stdin, timeout: timeout)
            }.value
            if out.timedOut { return .failure(.timedOut) }
            // ssh itself failed to connect — classify before looking at the
            // remote script's own exit code, which in that case never ran.
            if let transport = transportFailure(status: out.status, stderr: out.stderr) {
                return .failure(transport)
            }
            return .success(out)
        }
    }

    /// Map ssh's own errors to something the UI can act on. ssh exits 255 for
    /// every transport-level problem, so the text is the only discriminator.
    private static func transportFailure(status: Int32, stderr: String) -> Failure? {
        guard status == 255 || status < 0 else { return nil }
        let s = stderr.lowercased()
        if s.contains("host key verification failed")
            || s.contains("no matching host key")
            || s.contains("remote host identification has changed") {
            return .hostKeyUnverified
        }
        if s.contains("permission denied") || s.contains("authentication failed")
            || s.contains("too many authentication failures") {
            return .authenticationFailed(firstLine(stderr))
        }
        return .connectionFailed(firstLine(stderr))
    }

    private static func firstLine(_ s: String) -> String {
        s.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") } ?? ""
    }

    // MARK: - Probe

    /// Check the machine answers, find its home directory and its `claude`.
    ///
    /// The absolute `claude` path matters: the streaming session runs with a
    /// non-interactive PATH, and resolving the binary once here is what keeps
    /// the launch reproducible.
    static func probe(_ host: SSHHost) async -> Result<Probe, Failure> {
        let script = """
        printf 'HOME=%s\\n' "$HOME"
        printf 'UNAME=%s\\n' "$(uname -s 2>/dev/null)"
        c=""
        for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin "$HOME/.bun/bin" "$HOME/.npm-global/bin" /usr/bin /bin; do
          if [ -x "$d/claude" ]; then c="$d/claude"; break; fi
        done
        if [ -z "$c" ]; then c="$(command -v claude 2>/dev/null)"; fi
        printf 'CLAUDE=%s\\n' "$c"
        if [ -n "$c" ]; then printf 'VERSION=%s\\n' "$("$c" --version 2>/dev/null | head -n 1)"; fi
        """
        // Generous: a cold ssh handshake plus node's startup for `--version`.
        let result = await run(host, command: loginShellCommand(script), timeout: 30)
        switch result {
        case .failure(let f):
            return .failure(f)
        case .success(let out):
            let fields = parseFields(out.stdout)
            guard let home = fields["HOME"], !home.isEmpty else {
                return .failure(.connectionFailed(firstLine(out.stderr)))
            }
            let version = fields["VERSION"].flatMap { $0.isEmpty ? nil : $0 }
            return .success(Probe(home: home,
                                  uname: fields["UNAME"] ?? "",
                                  claudePath: fields["CLAUDE"] ?? "",
                                  claudeVersion: version))
        }
    }

    private static func parseFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            guard key.allSatisfy({ $0.isUppercase || $0 == "_" }) else { continue }
            fields[key] = String(line[line.index(after: eq)...])
        }
        return fields
    }

    // MARK: - Browsing

    /// List the subdirectories of `path`, flagging git repositories and folders
    /// that already carry a CLAUDE.md — the two markers that say "this is a
    /// project" when you're looking for somewhere to work.
    ///
    /// Only directories are returned: the point is choosing a working folder,
    /// and listing every file in a big repo would make the picker crawl.
    static func listDirectories(_ host: SSHHost, path: String) async -> Result<Listing, Failure> {
        let script = """
        p=$1
        if [ -z "$p" ] || [ "$p" = "~" ]; then p=$HOME; fi
        case "$p" in "~/"*) p="$HOME/${p#~/}";; esac
        if [ ! -e "$p" ]; then printf 'ERR=notfound\\n'; exit 3; fi
        if [ ! -d "$p" ]; then printf 'ERR=notdir\\n'; exit 3; fi
        cd -- "$p" 2>/dev/null || { printf 'ERR=denied\\n'; exit 3; }
        printf 'PATH_RESOLVED=%s\\n' "$(pwd -P)"
        s=""
        [ -e .git ] && s="${s}g"
        [ -f CLAUDE.md ] && s="${s}c"
        printf 'SELF=%s\\n' "$s"
        for e in * .*; do
          [ "$e" = "." ] && continue
          [ "$e" = ".." ] && continue
          [ -d "$e" ] || continue
          m=""
          [ -e "$e/.git" ] && m="${m}g"
          [ -f "$e/CLAUDE.md" ] && m="${m}c"
          printf 'D\\t%s\\t%s\\n' "$m" "$e"
        done
        """
        let result = await run(host, command: loginShellCommand(script, arguments: [path]))
        switch result {
        case .failure(let f):
            return .failure(f)
        case .success(let out):
            if let err = parseFields(out.stdout)["ERR"] {
                switch err {
                case "notfound": return .failure(.noSuchDirectory(path))
                case "notdir": return .failure(.notADirectory(path))
                default: return .failure(.permissionDenied(path))
                }
            }
            guard out.status == 0 else {
                return .failure(.remoteError(firstLine(out.stderr).isEmpty
                                             ? "exit \(out.status)" : firstLine(out.stderr)))
            }
            let fields = parseFields(out.stdout)
            let resolved = fields["PATH_RESOLVED"] ?? path
            let selfMarks = fields["SELF"] ?? ""
            var entries: [RemoteEntry] = []
            for line in out.stdout.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2,
                                       omittingEmptySubsequences: false)
                guard parts.count == 3, parts[0] == "D" else { continue }
                let marks = parts[1]
                entries.append(RemoteEntry(name: String(parts[2]),
                                           isGitRepo: marks.contains("g"),
                                           hasClaudeMD: marks.contains("c")))
            }
            entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return .success(Listing(path: resolved, entries: entries,
                                    isGitRepo: selfMarks.contains("g"),
                                    hasClaudeMD: selfMarks.contains("c")))
        }
    }

    /// Create a directory inside `parent` and return its canonical path.
    static func makeDirectory(_ host: SSHHost, parent: String,
                              name: String) async -> Result<String, Failure> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"),
              trimmed != ".", trimmed != ".." else { return .failure(.invalidName) }

        let script = """
        cd -- "$1" 2>/dev/null || { printf 'ERR=nodir\\n'; exit 3; }
        if [ -e "$2" ]; then printf 'ERR=exists\\n'; exit 4; fi
        mkdir -- "$2" || { printf 'ERR=mkdir\\n'; exit 5; }
        printf 'PATH_RESOLVED=%s\\n' "$(cd -- "$2" && pwd -P)"
        """
        let result = await run(host, command: loginShellCommand(script,
                                                                arguments: [parent, trimmed]))
        switch result {
        case .failure(let f):
            return .failure(f)
        case .success(let out):
            let fields = parseFields(out.stdout)
            if let err = fields["ERR"] {
                switch err {
                case "nodir": return .failure(.noSuchDirectory(parent))
                case "exists": return .failure(.alreadyExists(trimmed))
                default: return .failure(.permissionDenied(parent + "/" + trimmed))
                }
            }
            guard let path = fields["PATH_RESOLVED"], !path.isEmpty else {
                return .failure(.remoteError(firstLine(out.stderr)))
            }
            return .success(path)
        }
    }

    // MARK: - Files

    /// Read a remote text file. A missing file reads as empty — the CLAUDE.md
    /// editor treats "not there yet" and "empty" the same way.
    static func readFile(_ host: SSHHost, path: String) async -> Result<String, Failure> {
        let script = """
        [ -f "$1" ] || exit 44
        cat -- "$1"
        """
        let result = await run(host, command: loginShellCommand(script, arguments: [path]),
                               timeout: 25)
        switch result {
        case .failure(let f):
            return .failure(f)
        case .success(let out):
            if out.status == 44 { return .success("") }
            guard out.status == 0 else { return .failure(.permissionDenied(path)) }
            return .success(out.stdout)
        }
    }

    /// Write a remote text file through a sibling temp file and an atomic `mv`,
    /// so a connection that drops mid-transfer can't leave the original truncated.
    static func writeFile(_ host: SSHHost, path: String,
                          content: String) async -> Result<Void, Failure> {
        let script = """
        t="$1.maccl.$$"
        cat > "$t" || { rm -f "$t"; exit 5; }
        chmod 644 "$t" 2>/dev/null
        mv -- "$t" "$1" || { rm -f "$t"; exit 5; }
        """
        let data = Data(content.utf8)
        let result = await run(host, command: loginShellCommand(script, arguments: [path]),
                               stdin: data, timeout: 30)
        switch result {
        case .failure(let f):
            return .failure(f)
        case .success(let out):
            guard out.status == 0 else { return .failure(.permissionDenied(path)) }
            return .success(())
        }
    }

    // MARK: - Host keys

    enum HostKeyState: Equatable, Sendable {
        case known
        case unknown([String])   // fingerprints offered by the machine
        /// Nothing answered on the SSH port. Deliberately carries no message:
        /// this runs off the main actor where L10n isn't reachable, and an
        /// English fragment glued onto a French sentence is worse than none.
        case unreachable
    }

    /// The known_hosts entry name: bare host on port 22, `[host]:port` otherwise.
    private static func knownHostsSpec(_ host: SSHHost) -> String {
        host.port == 22 ? host.hostname : "[\(host.hostname)]:\(host.port)"
    }

    /// Is this machine's key already trusted, and if not, what is it offering?
    ///
    /// Presented to the user before the first connection: MacCL never adds a key
    /// on its own, because silently trusting whatever answers is exactly how a
    /// man-in-the-middle gets an agent running with bypassed permissions.
    static func hostKeyState(_ host: SSHHost) async -> HostKeyState {
        guard host.isUsable else { return .unreachable }
        if await Task.detached(priority: .userInitiated, operation: { isKnown(host) }).value {
            return .known
        }
        let prints = await scanFingerprints(host)
        return prints.isEmpty ? .unreachable : .unknown(prints)
    }

    private static func isKnown(_ host: SSHHost) -> Bool {
        guard let keygen = BinaryLocator.find("ssh-keygen") else { return false }
        let out = execute(Launch(executable: keygen,
                                 arguments: ["-F", knownHostsSpec(host)],
                                 environment: [:]),
                          timeout: 10)
        return out.status == 0 && !out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Raw known_hosts lines the machine offers, via ssh-keyscan.
    private static func scanKeys(_ host: SSHHost) -> String {
        guard let keyscan = BinaryLocator.find("ssh-keyscan") else { return "" }
        var args = ["-T", "8"]
        if host.port != 22 { args += ["-p", String(host.port)] }
        args.append(host.hostname)
        let out = execute(Launch(executable: keyscan, arguments: args, environment: [:]),
                          timeout: 15)
        return out.stdout
    }

    /// Human-readable fingerprints ("256 SHA256:… ED25519") for confirmation.
    private static func scanFingerprints(_ host: SSHHost) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            let keys = scanKeys(host)
            guard !keys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let keygen = BinaryLocator.find("ssh-keygen") else { return [] }
            let out = execute(Launch(executable: keygen, arguments: ["-lf", "-"],
                                     environment: [:]),
                              stdin: Data(keys.utf8), timeout: 10)
            return out.stdout.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }.value
    }

    /// Trust this machine's key: append what ssh-keyscan reports to known_hosts.
    /// Only ever called from the button the user pressed after reading the
    /// fingerprint.
    static func acceptHostKey(_ host: SSHHost) async -> Result<Void, Failure> {
        let keys = await Task.detached(priority: .userInitiated) { scanKeys(host) }.value
        let trimmed = keys.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.noHostKey) }

        let fm = FileManager.default
        let sshDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        let knownHosts = sshDir.appendingPathComponent("known_hosts")
        do {
            if !fm.fileExists(atPath: sshDir.path) {
                try fm.createDirectory(at: sshDir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
            if let handle = FileHandle(forWritingAtPath: knownHosts.path) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(("\n" + trimmed + "\n").utf8))
            } else {
                try (trimmed + "\n").write(to: knownHosts, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHosts.path)
            }
        } catch {
            return .failure(.remoteError(error.localizedDescription))
        }
        AppLog.info("ssh", "host key accepted for \(knownHostsSpec(host))")
        return .success(())
    }

    // MARK: - Running claude remotely

    /// The ssh options that make a Mac-local Ollama reachable from the remote
    /// machine, plus the port they forward.
    ///
    /// `ANTHROPIC_BASE_URL=http://localhost:11434` means *the remote's* localhost
    /// once `claude` runs over there — pointing the conversation at whatever
    /// Ollama happens to live on that box, which is precisely the silent
    /// re-routing this app refuses to do. A reverse tunnel keeps the address
    /// honest, and `ExitOnForwardFailure` makes a busy remote port a loud failure
    /// instead of a wrong answer.
    static func reverseTunnel(forServerURL url: String) -> (options: [String], port: Int)? {
        guard let comps = URLComponents(string: url),
              let host = comps.host?.lowercased() else { return nil }
        let localNames: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]
        guard localNames.contains(host) else { return nil }
        let port = comps.port ?? URLValidator.defaultOllamaPort
        return (["-R", "127.0.0.1:\(port):127.0.0.1:\(port)",
                 "-o", "ExitOnForwardFailure=yes"], port)
    }

    /// The remote side of a `claude` session: cd into the working directory and
    /// exec the binary with the environment it needs.
    ///
    /// `exec` replaces the login shell, so terminating the ssh client takes the
    /// agent down with it instead of orphaning a process on the remote machine.
    static func claudeCommand(directory: String,
                              claudePath: String,
                              arguments: [String],
                              environment: [String: String]) -> String {
        let assignments = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shellQuote($0.value))" }
            .joined(separator: " ")
        let binary = claudePath.isEmpty ? "claude" : claudePath
        let envPrefix = assignments.isEmpty ? "" : "env " + assignments + " "
        let invocation = envPrefix + shellQuote(binary) + " "
            + arguments.map(shellQuote).joined(separator: " ")
        let script = """
        cd -- \(shellQuote(directory)) || exit 66
        exec \(invocation)
        """
        return loginShellCommand(script)
    }

    /// Options for the long-lived streaming session: keep the connection from
    /// being dropped by a NAT or an idle timer while a long turn runs.
    static let keepAliveOptions = [
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=6",
    ]
}
