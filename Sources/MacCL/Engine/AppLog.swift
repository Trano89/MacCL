import Foundation

/// Append-only diagnostic log at ~/Library/Logs/MacCL/maccl.log.
///
/// The bridges (Node router, LiteLLM) and the `claude` child all write to stderr;
/// without this their output was drained and dropped, so failures like "it ran
/// two minutes then nothing" left no trace. Everything lands here instead.
enum AppLog {
    private static let queue = DispatchQueue(label: "maccl.applog")
    private static let maxBytes = 4 * 1024 * 1024

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MacCL", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("maccl.log")
    }

    /// Log one line, tagged by source (e.g. "router", "litellm", "claude").
    static func write(_ source: String, _ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] [\(source)] \(text)\n"
            guard let data = line.data(using: .utf8) else { return }
            let url = fileURL
            rotateIfNeeded(url)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Keep one previous generation so the log can't grow without bound.
    private static func rotateIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes else { return }
        let old = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
