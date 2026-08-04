import Foundation
import Dispatch

/// Everything needed to launch a `claude` streaming session.
struct SessionConfig {
    var claudePath: String
    var workingDirectory: String
    /// nil = run on this Mac. Non-nil = run `claude` on that machine over ssh,
    /// with `workingDirectory` read on the remote filesystem. Everything else in
    /// this struct is unchanged: the CLI arguments and the newline-delimited JSON
    /// protocol are identical whether the process is local or a pipe through ssh.
    var remoteHost: SSHHost?
    var model: LLMModel
    var permissionMode: PermissionMode
    var effort: EffortLevel
    var appendSystemPrompt: String
    var streamPartial: Bool
    var sessionId: String
    /// Cap on one reply's output tokens. 0 = leave the CLI's own default alone.
    var maxOutputTokens: Int = 64_000
    /// Extra environment (points `claude` at the conversation's Ollama server).
    var extraEnv: [String: String] = [:]
    /// Reverse-tunnel options when the conversation's Ollama runs on this Mac and
    /// `claude` runs elsewhere — see `SSHClient.reverseTunnel(forServerURL:)`.
    var reverseTunnelOptions: [String] = []

    var isRemote: Bool { remoteHost != nil }

    /// The environment `claude` itself must see. Locally these are applied to the
    /// child process; remotely they ride along in the command's `env` prefix,
    /// because ssh forwards no environment by default.
    ///
    /// App-level plumbing lives here rather than in `extraEnv` so it stays out of
    /// the command shown to the user — it isn't part of the session's identity.
    func childEnvironment(inherited: [String: String]) -> [String: String] {
        var env: [String: String] = [:]
        // Long agentic turns can exceed claude's default 32k output-token cap,
        // killing the turn ("response exceeded the 32000 output token maximum").
        if inherited["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == nil, maxOutputTokens > 0 {
            env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = String(maxOutputTokens)
        }
        // Ollama's /v1/messages sends nothing while a model cold-loads and the
        // prompt evaluates (62 s measured); claude's default timeout sits right
        // there and turned cold turns into a retry loop. Harmless for Anthropic.
        if inherited["API_TIMEOUT_MS"] == nil {
            env["API_TIMEOUT_MS"] = "600000"
        }
        // Background calls would evict the conversation's prompt cache on an
        // Ollama server — one stray request and the next turn re-evaluates the
        // whole prefix.
        if inherited["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == nil {
            env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        }
        for (k, v) in extraEnv { env[k] = v }
        return env
    }

    /// The `claude` arguments, built ONCE for both the real spawn and the
    /// transcript display so they can never drift apart. Strict minimum per the
    /// CLI reference — a flag only appears when it changes something:
    /// - `--verbose` stays: `-p --output-format stream-json` refuses to run
    ///   without it (verified against 2.1.207, whatever the docs suggest).
    /// - `--permission-mode` only when not the CLI default.
    /// - No `--effort` at all: the reasoning level is applied AFTER launch by
    ///   sending `/effort <level>` in-band (verified: "Set effort level … (this
    ///   session only)"), which also makes it changeable mid-conversation.
    func cliArguments(resume: Bool, forDisplay: Bool = false) -> [String] {
        var args = ["-p", "--input-format", "stream-json",
                    "--output-format", "stream-json", "--verbose",
                    "--model", model.modelArg]
        if permissionMode != .defaultMode {
            args += ["--permission-mode", permissionMode.cliValue]
        }
        if streamPartial { args += ["--include-partial-messages"] }
        if !appendSystemPrompt.isEmpty {
            args += ["--append-system-prompt",
                     forDisplay ? "\"$(cat instructions/*.md)\"" : appendSystemPrompt]
        }
        args += resume ? ["--resume", sessionId] : ["--session-id", sessionId]
        return args
    }

    /// The session as a human would type it in a terminal, used by the launch
    /// notice and by the new-conversation preview. Same builders as the real
    /// spawn, so the two can't drift.
    ///
    /// A remote session is shown as the three steps it really is — connect, cd,
    /// run — rather than the single quoted blob that crosses the wire: the point
    /// is for the user to recognise their own command, not to audit the escaping.
    static func displayCommand(config: SessionConfig, resumed: Bool) -> String {
        let env = config.extraEnv
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let prefix = env.isEmpty ? "" : env + " "
        let args = config.cliArguments(resume: resumed, forDisplay: true).joined(separator: " ")

        var lines: [String] = []
        if let host = config.remoteHost {
            // Only the options that change the outcome: the boilerplate
            // (-T, timeouts, keep-alives, strict host-key checking) is noise here.
            var sshArgs: [String] = []
            if host.port != 22 { sshArgs += ["-p", String(host.port)] }
            if !host.identityFile.isEmpty { sshArgs += ["-i", host.identityFile] }
            sshArgs += config.reverseTunnelOptions.filter { $0 != "-o" && !$0.hasPrefix("ExitOnForward") }
            lines.append("$ ssh " + (sshArgs + [host.target]).joined(separator: " "))
            // The real binary path, resolved on the remote by the probe.
            let binary = host.remoteClaudePath.isEmpty ? "claude" : host.remoteClaudePath
            lines.append("$ cd \"\(config.workingDirectory)\"")
            lines.append("$ \(prefix)\(binary) \(args)")
        } else {
            // The real binary path, not a bare "claude": a CLI installed outside
            // the PATH would otherwise be misreported.
            lines.append("$ cd \"\(config.workingDirectory)\"")
            lines.append("$ \(prefix)\(config.claudePath) \(args)")
        }
        lines.append("> /effort \(config.effort.cliValue)")
        return lines.joined(separator: "\n")
    }
}

/// Drives a single long-lived `claude -p --input-format stream-json` process.
///
/// One `ClaudeSession` maps to one conversation: the process stays alive across
/// turns, receiving user messages on stdin and emitting protocol events on
/// stdout. Callbacks are always delivered on the main queue.
final class ClaudeSession {
    // Callbacks (delivered on main).
    var onEvent: ((StreamEnvelope) -> Void)?
    var onStderr: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    private(set) var config: SessionConfig?
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private let bufferQueue = DispatchQueue(label: "claudemac.session.buffer")
    /// Track the pipe handles so we can nil their handlers on stop.
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Lifecycle

    /// Launch the process and send the first user turn. Pass `resume: true` to
    /// continue a persisted session (loaded from history) via --resume.
    /// `preCommands` are slash commands (e.g. "/effort high") written BEFORE the
    /// first turn, so they apply to it — each produces its own instant result.
    func start(config: SessionConfig, firstContent blocks: [[String: Any]],
               resume: Bool = false, preCommands: [String] = []) throws {
        self.config = config
        try spawn(config: config, resume: resume)
        for cmd in preCommands { sendCommand(cmd) }
        write(content: blocks)
    }

    /// Send a slash command (or any plain text) as its own in-band user turn.
    func sendCommand(_ text: String) {
        write(content: [["type": "text", "text": text]])
    }

    /// Send a follow-up user turn, restarting (via --resume) if the process died.
    func send(content blocks: [[String: Any]]) {
        guard let config else { return }
        if isRunning {
            write(content: blocks)
        } else {
            do {
                try spawn(config: config, resume: true)
                write(content: blocks)
            } catch {
                deliver(stderr: "Impossible de relancer la session : \(error.localizedDescription)")
            }
        }
    }

    /// Abort the current turn but KEEP the process alive, so the next user
    /// message continues in the same session (no restart, no session-id clash).
    func interrupt() {
        writeRaw([
            "type": "control_request",
            "request_id": "interrupt-\(UUID().uuidString)",
            "request": ["subtype": "interrupt"],
        ])
    }

    func stop() {
        // Clear readability handlers to prevent old-session callbacks from firing.
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutBuffer.removeAll()
        process?.terminate()
        process = nil
    }

    // MARK: - Spawning

    private func spawn(config: SessionConfig, resume: Bool) throws {
        let proc = Process()
        let args = config.cliArguments(resume: resume)

        // Environment: inherit, then guarantee a usable PATH.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BinaryLocator.mergedPATH(base: env["PATH"])

        if let host = config.remoteHost {
            // Remote: ssh becomes the child process. Its stdin/stdout carry the
            // exact same newline-delimited JSON, so everything downstream — the
            // buffering, the decoder, the callbacks — is untouched.
            //
            // The remote gets a clean slate for the child environment: ssh
            // forwards nothing, so `inherited` is empty and every variable
            // `claude` needs is written into the command's own `env` prefix.
            let remoteEnv = config.childEnvironment(inherited: [:])
            let command = SSHClient.claudeCommand(directory: config.workingDirectory,
                                                  claudePath: host.remoteClaudePath,
                                                  arguments: args,
                                                  environment: remoteEnv)
            let options = SSHClient.keepAliveOptions + config.reverseTunnelOptions
            switch SSHClient.launch(for: host, remoteCommand: command, extraOptions: options) {
            case .failure(let failure):
                throw failure
            case .success(let launch):
                proc.executableURL = URL(fileURLWithPath: launch.executable)
                proc.arguments = launch.arguments
                for (k, v) in launch.environment { env[k] = v }
            }
        } else {
            proc.executableURL = URL(fileURLWithPath: config.claudePath)
            proc.currentDirectoryURL = URL(fileURLWithPath: config.workingDirectory)
            proc.arguments = args
            // App-level tuning, kept OUT of the displayed launch command — it's
            // plumbing, not session identity.
            for (k, v) in config.childEnvironment(inherited: env) { env[k] = v }
        }
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        self.stdinPipe = stdinPipe

        // Make pipe fds non-blocking instead of globally suppressing SIGPIPE.
        // signal(SIGPIPE, SIG_IGN) is DANGEROUS — it affects ALL threads in the app,
        // not just this process. A library that legitimately writes to a closed socket
        // would silently crash rather than getting an EPIPE error.
        setNonBlocking(stdinPipe.fileHandleForWriting.fileDescriptor)
        setNonBlocking(stdoutPipe.fileHandleForReading.fileDescriptor)
        setNonBlocking(stderrPipe.fileHandleForReading.fileDescriptor)

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle

        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(stdout: data)
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            self?.deliver(stderr: s)
        }
        proc.terminationHandler = { [weak self] p in
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            DispatchQueue.main.async { self?.onExit?(p.terminationStatus) }
        }

        try proc.run()
        self.process = proc
    }

    // MARK: - Pipe helpers

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFD, flags | O_NONBLOCK)
    }

    // MARK: - Writing

    private func write(content blocks: [[String: Any]]) {
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": blocks,
            ],
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A) // newline-delimited
        guard let handle = stdinPipe?.fileHandleForWriting else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            deliver(stderr: "Écriture stdin échouée : \(error.localizedDescription)")
        }
    }

    /// Write a raw control-protocol / SDK message (used later for permissions).
    func writeRaw(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? stdinPipe?.fileHandleForWriting.write(contentsOf: data)
    }

    // MARK: - Reading

    private func ingest(stdout data: Data) {
        bufferQueue.async { [weak self] in
            guard let self else { return }
            self.stdoutBuffer.append(data)
            while let newlineRange = self.stdoutBuffer.range(of: Data([0x0A])) {
                let lineData = self.stdoutBuffer.subdata(in: self.stdoutBuffer.startIndex..<newlineRange.lowerBound)
                self.stdoutBuffer.removeSubrange(self.stdoutBuffer.startIndex..<newlineRange.upperBound)
                self.decode(lineData)
            }
        }
    }

    private func decode(_ lineData: Data) {
        guard !lineData.isEmpty else { return }
        do {
            let env = try JSONDecoder().decode(StreamEnvelope.self, from: lineData)
            DispatchQueue.main.async { [weak self] in self?.onEvent?(env) }
        } catch {
            // Non-JSON line (rare warnings). Surface as stderr-ish notice.
            if let s = String(data: lineData, encoding: .utf8),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                deliver(stderr: s)
            }
        }
    }

    private func deliver(stderr text: String) {
        DispatchQueue.main.async { [weak self] in self?.onStderr?(text) }
    }
}
