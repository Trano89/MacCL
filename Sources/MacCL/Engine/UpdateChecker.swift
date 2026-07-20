import Foundation

/// Checks the GitHub repository for a newer release.
/// Read-only: it compares versions and hands the user the release page —
/// downloading and swapping the app stays a deliberate user action.
enum UpdateChecker {
    static let repo = "Trano89/MacCL"
    static let releasesPage = URL(string: "https://github.com/Trano89/MacCL/releases/latest")!

    /// The running app's version, straight from the bundle.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    struct Outcome {
        let latestTag: String
        let isNewer: Bool
    }

    /// nil error on success. A 404 usually means the repository is private —
    /// say so instead of a generic failure.
    static func check() async -> (outcome: Outcome?, error: String?) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return (nil, "URL invalide")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                return (nil, await L10n.t(code == 404 ? "update_repo_unreachable" : "update_error"))
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                return (nil, await L10n.t("update_error"))
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            return (Outcome(latestTag: latest,
                            isNewer: isVersion(latest, newerThan: currentVersion)), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// Numeric component-by-component comparison: "0.1.10" > "0.1.9".
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
