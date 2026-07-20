import Foundation

/// Where MacCL stores its data: instruction library and conversation history.
enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("MacCL", isDirectory: true))
    }

    static var instructions: URL { ensure(support.appendingPathComponent("instructions", isDirectory: true)) }
    static var conversations: URL { ensure(support.appendingPathComponent("conversations", isDirectory: true)) }

    /// Remove what the retired LiteLLM bridge left behind. MacCL used to offer
    /// LiteLLM as an alternative route to Ollama and installed a Python virtual
    /// environment for it (~550 MB observed). The bridge is gone — Ollama serves
    /// the Anthropic API itself — but the venv stayed on disk, invisible and
    /// useless. Runs once; deleting nothing is the normal case.
    static func removeRetiredLiteLLMLeftovers() {
        let fm = FileManager.default
        for name in ["litellm-venv", "litellm-config.yaml"] {
            let url = support.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let size = (try? fm.allocatedSizeOfDirectory(at: url)) ?? 0
            do {
                try fm.removeItem(at: url)
                AppLog.info("cleanup", "removed retired LiteLLM leftover \(name)"
                            + (size > 0 ? " (\(Int64(size).formattedBytes))" : ""))
            } catch {
                AppLog.warn("cleanup", "could not remove \(name): \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension FileManager {
    /// Total bytes used by a file or directory tree — for reporting what a
    /// cleanup actually reclaimed.
    func allocatedSizeOfDirectory(at url: URL) throws -> UInt64 {
        var isDir: ObjCBool = false
        guard fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var total: UInt64 = 0
        guard let e = enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return 0 }
        for case let child as URL in e {
            let values = try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
