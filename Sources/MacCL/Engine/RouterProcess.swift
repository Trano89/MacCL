import Foundation
import Network

/// Manages the local Node process that translates the Anthropic Messages API
/// into Ollama calls. Started on demand when a local model is selected.
final class RouterProcess {
    private var process: Process?
    private var currentPort: Int?
    private var currentCtx: Int?
    private var currentThink: Bool?
    private var currentMaxPredict: Int?

    var isRunning: Bool { process?.isRunning ?? false }

    /// Ensure the router is up on `port`. Returns nil on success, else an error.
    @MainActor
    func ensureRunning(port: Int, ollamaBaseURL: String, numCtx: Int, think: Bool, maxPredict: Int) async -> String? {
        // Validate ollamaBaseURL before using as process arg — prevents command injection.
        guard URLValidator.validate(ollamaBaseURL) != nil else {
            return L10n.t("invalid_ollama_url")
        }

        // Already running with the same config and healthy?
        if isRunning, currentPort == port, currentCtx == numCtx, currentThink == think,
           currentMaxPredict == maxPredict, await isHealthy(port: port) {
            return nil
        }
        stop()

        guard let node = BinaryLocator.find("node") else {
            return "Node introuvable. Installez Node.js (le routeur local en a besoin pour parler à Ollama)."
        }
        guard let script = Self.resolveScript() else {
            return "Script du routeur introuvable dans le bundle de l'app."
        }
        guard await OllamaClient.isReachable(baseURL: ollamaBaseURL) else {
            return "Serveur Ollama injoignable à \(ollamaBaseURL). Lancez `ollama serve`."
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: node)
        var routerArgs = [script.path, "--port", String(port), "--ollama", ollamaBaseURL,
                          "--ctx", String(numCtx), "--max-predict", String(maxPredict),
                          "--keep-alive", "-1"]
        if think { routerArgs.append("--think") }
        proc.arguments = routerArgs
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BinaryLocator.mergedPATH(base: env["PATH"])
        proc.environment = env
        // Keep the router quiet; it logs to stderr which we drain.
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            _ = h.availableData // drained; router logs are best-effort
        }

        do {
            try proc.run()
        } catch {
            return "Impossible de lancer le routeur : \(error.localizedDescription)"
        }
        self.process = proc
        self.currentPort = port
        self.currentCtx = numCtx
        self.currentThink = think
        self.currentMaxPredict = maxPredict

        // Wait for the router to accept connections.
        for _ in 0..<20 {
            if await isHealthy(port: port) { return nil }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return "Le routeur local n'a pas démarré à temps sur le port \(port)."
    }

    func stop() {
        process?.terminate()
        process = nil
        currentPort = nil
        currentCtx = nil
        currentThink = nil
        currentMaxPredict = nil
    }

    private func isHealthy(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.0
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Locate the bundled router script (or the repo copy during development).
    static func resolveScript() -> URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            let candidates = [
                res.appendingPathComponent("router/anthropic-ollama-proxy.mjs"),
                res.appendingPathComponent("anthropic-ollama-proxy.mjs"),
            ]
            for c in candidates where fm.fileExists(atPath: c.path) { return c }
        }
        // Development fallback: walk up from the executable to find the repo.
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("router/anthropic-ollama-proxy.mjs")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

}
