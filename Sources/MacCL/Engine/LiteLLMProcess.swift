import Foundation

/// Manages a local [LiteLLM](https://github.com/BerriAI/litellm) proxy that
/// bridges Claude Code's Anthropic Messages API to an Ollama server.
///
/// Why LiteLLM in addition to the built-in Node router: it's the community's
/// battle-tested bridge, with strict network guard-rails — a good fit for a
/// *remote* Ollama, where a flaky link is the main failure mode.
///
/// It is Python software, so it lives in a self-provisioned venv under
/// Application Support; nothing is installed system-wide.
@MainActor
final class LiteLLMProcess {

    /// How the proxy is doing — surfaced in Preferences.
    enum State: Equatable {
        case notInstalled
        case installing
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
    }

    private(set) var state: State = .stopped

    private var process: Process?
    private var currentPort: Int?
    private var currentTarget: String?

    /// Pythons that have prebuilt wheels for LiteLLM's deps (orjson has none for
    /// 3.14 yet, and building it needs Rust) — newest supported first.
    private static let pythonCandidates = ["python3.13", "python3.12", "python3.11"]

    static var venvDirectory: URL { AppPaths.support.appendingPathComponent("litellm-venv", isDirectory: true) }
    static var binary: URL { venvDirectory.appendingPathComponent("bin/litellm") }
    private static var configFile: URL { AppPaths.support.appendingPathComponent("litellm-config.yaml") }

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.binary.path) }
    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Install

    /// A Python that can install LiteLLM, if any is present on the machine.
    static func usablePython() -> String? {
        for name in pythonCandidates {
            if let path = BinaryLocator.find(name) { return path }
        }
        // Fall back to plain python3 only if it isn't the too-new 3.14+.
        guard let py = BinaryLocator.find("python3") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = ["-c", "import sys; print(sys.version_info[:2] < (3, 14))"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.contains("True") ? py : nil
    }

    /// Create the venv and `pip install litellm[proxy]`. Long-running (minutes).
    func install(progress: @escaping (String) -> Void) async -> String? {
        guard let python = Self.usablePython() else {
            state = .notInstalled
            return L10n.t("litellm_no_python")
        }
        state = .installing
        progress(L10n.t("litellm_creating_venv"))
        if !FileManager.default.fileExists(atPath: Self.venvDirectory.path) {
            if let err = await run(python, ["-m", "venv", Self.venvDirectory.path]) {
                state = .failed(err)
                return err
            }
        }
        progress(L10n.t("litellm_installing"))
        let pip = Self.venvDirectory.appendingPathComponent("bin/pip").path
        if let err = await run(pip, ["install", "--quiet", "--upgrade", "litellm[proxy]"]) {
            state = .failed(err)
            return err
        }
        guard isInstalled else {
            let err = L10n.t("litellm_install_failed")
            state = .failed(err)
            return err
        }
        state = .stopped
        return nil
    }

    /// Run a command to completion; returns nil on success, else stderr tail.
    private func run(_ launchPath: String, _ args: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = BinaryLocator.mergedPATH(base: env["PATH"])
            p.environment = env
            let errPipe = Pipe()
            p.standardError = errPipe
            p.standardOutput = Pipe()
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: String(text.suffix(400)))
                }
            }
            do { try p.run() } catch { continuation.resume(returning: error.localizedDescription) }
        }
    }

    // MARK: - Run

    /// Ensure a LiteLLM proxy is serving `/v1/messages` on `port`, bridging to
    /// `ollamaBaseURL`. Returns nil on success, else an error message.
    func ensureRunning(port: Int, ollamaBaseURL: String) async -> String? {
        guard isInstalled else {
            state = .notInstalled
            return L10n.t("litellm_not_installed")
        }
        if isRunning, currentPort == port, currentTarget == ollamaBaseURL, await isHealthy(port: port) {
            return nil
        }
        stop()

        // One wildcard entry routes every Ollama model, so the config never has
        // to be rewritten when the user switches models.
        let config = """
        model_list:
          - model_name: "*"
            litellm_params:
              model: "ollama_chat/*"
              api_base: \(ollamaBaseURL)
        litellm_settings:
          drop_params: true
        """
        do {
            try config.write(to: Self.configFile, atomically: true, encoding: .utf8)
        } catch {
            let err = "\(L10n.t("litellm_config_failed")): \(error.localizedDescription)"
            state = .failed(err)
            return err
        }

        state = .starting
        let p = Process()
        p.executableURL = Self.binary
        p.arguments = ["--config", Self.configFile.path, "--port", String(port)]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BinaryLocator.mergedPATH(base: env["PATH"])
        p.environment = env
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            AppLog.write("litellm", text)
        }
        p.terminationHandler = { proc in
            AppLog.write("litellm", "proxy exited: code=\(proc.terminationStatus)")
        }
        do {
            try p.run()
        } catch {
            let err = "\(L10n.t("litellm_start_failed")): \(error.localizedDescription)"
            state = .failed(err)
            return err
        }
        process = p
        currentPort = port
        currentTarget = ollamaBaseURL

        // Cold start takes a few seconds (imports + model registry).
        for _ in 0..<40 {
            if await isHealthy(port: port) {
                state = .running(port: port)
                return nil
            }
            if !p.isRunning { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        stop()
        let err = L10n.t("litellm_start_timeout")
        state = .failed(err)
        return err
    }

    func stop() {
        process?.terminate()
        process = nil
        currentPort = nil
        currentTarget = nil
        if case .running = state { state = .stopped }
    }

    private func isHealthy(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health/liveliness") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
