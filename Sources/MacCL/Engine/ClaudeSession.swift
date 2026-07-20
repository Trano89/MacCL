import Foundation
import Dispatch

/// Everything needed to launch a `claude` streaming session.
struct SessionConfig {
    var claudePath: String
    var workingDirectory: String
    var model: LLMModel
    var permissionMode: PermissionMode
    var effort: EffortLevel
    var appendSystemPrompt: String
    var streamPartial: Bool
    var sessionId: String
    /// Extra environment (used by the local router to point at Ollama, etc.).
    var extraEnv: [String: String] = [:]
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
    func start(config: SessionConfig, firstContent blocks: [[String: Any]], resume: Bool = false) throws {
        self.config = config
        try spawn(config: config, resume: resume)
        write(content: blocks)
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
        // 1) Remove readability handlers first — prevents new callbacks from being queued.
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        // 2) Clear the session's own property references so nothing can fire after this.
        let prevStdout = stdoutHandle
        let prevStderr = stderrHandle
        let prevStdin = stdinPipe
        stdoutHandle = nil
        stderrHandle = nil
        stdinPipe = nil
        // 3) Clear buffered data (already-flowing bytes are stale).
        stdoutBuffer.removeAll()
        // 4) Terminate the process — it will run its own terminationHandler which
        //    also nils local handle copies, but those are now our dead copies.
        process?.terminate()
        process = nil
    }

    // MARK: - Spawning

    private func spawn(config: SessionConfig, resume: Bool) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.claudePath)
        proc.currentDirectoryURL = URL(fileURLWithPath: config.workingDirectory)

        var args: [String] = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--model", config.model.modelArg,
            "--permission-mode", config.permissionMode.cliValue,
            "--effort", config.effort.cliValue,
        ]
        if config.streamPartial {
            args += ["--include-partial-messages"]
        }
        if !config.appendSystemPrompt.isEmpty {
            args += ["--append-system-prompt", config.appendSystemPrompt]
        }
        if resume {
            args += ["--resume", config.sessionId]
        } else {
            args += ["--session-id", config.sessionId]
        }
        proc.arguments = args

        // Environment: inherit, then guarantee a usable PATH and apply overrides.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BinaryLocator.mergedPATH(base: env["PATH"])
        // Long agentic turns can exceed claude's default 32k output-token cap,
        // killing the turn ("response exceeded the 32000 output token maximum").
        if env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == nil {
            env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = "64000"
        }
        for (k, v) in config.extraEnv { env[k] = v }
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
