import Foundation

/// Resolves CLI executables. GUI apps launched from Finder inherit a minimal
/// PATH, so we probe well-known install locations and fall back to a login shell.
enum BinaryLocator {
    /// Directories to prepend to the child process PATH so `claude` can find
    /// `node`, `ollama`, git, etc.
    static var augmentedPATHDirectories: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
        ]
    }

    static func find(_ name: String, override: String? = nil) -> String? {
        if let o = override, !o.isEmpty,
           FileManager.default.isExecutableFile(atPath: o) {
            return o
        }
        for dir in augmentedPATHDirectories {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return whichViaLoginShell(name)
    }

    /// Last resort: ask the user's login shell where the binary lives.
    static func whichViaLoginShell(_ name: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Sanitize to prevent shell injection — only allow safe characters.
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", "command -v '\(name)'"]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!path.isEmpty && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
    }

    /// Build a PATH string that merges the inherited PATH with known dirs.
    static func mergedPATH(base: String?) -> String {
        var seen = Set<String>()
        var dirs: [String] = []
        for dir in augmentedPATHDirectories + ((base ?? "").split(separator: ":").map(String.init)) {
            if !dir.isEmpty && !seen.contains(dir) {
                seen.insert(dir)
                dirs.append(dir)
            }
        }
        return dirs.joined(separator: ":")
    }
}
