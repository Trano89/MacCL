import Foundation

/// Where ClaudeMac stores its data: instruction library and conversation history.
enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("ClaudeMac", isDirectory: true))
    }

    static var instructions: URL { ensure(support.appendingPathComponent("instructions", isDirectory: true)) }
    static var conversations: URL { ensure(support.appendingPathComponent("conversations", isDirectory: true)) }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
