import Foundation

/// Shared URL validator used throughout MacCL to validate Ollama server URLs.
/// Centralized here to prevent validation drift between AppSettings and ModelRouter.
///
/// ## Design rationale
/// - **Single source of truth**: Every file that deals with a server URL calls `sanitizeAndValidate`
///   or `validateServerURL`. This prevents one module from accepting what another rejects.
/// - **Sanitization before validation**: The public `sanitizeAndValidate` method auto-corrects common
///   user-entry mistakes (missing scheme, stray whitespace) so the UI can show green early.
/// - **No URL(string:) crash risk**: All parsing is done with optional binding; malformed URLs are
///   captured at parse time and never force-unwrapped.
enum URLValidator {

    // MARK: - Public API

    /// The port Ollama listens on unless told otherwise.
    static let defaultOllamaPort = 11434

    /// Sanitize then validate a server URL string.
    ///
    /// Returns the validated (possibly sanitized) URL string, or `nil` if the input cannot be made valid.
    /// Sanitization steps (applied before validation):
    /// 1. Trim leading/trailing whitespace (common copy-paste artifact).
    /// 2. Prepend `"http://"` if no scheme is present — Ollama servers typically use HTTP in local setups.
    /// 3. Append `":11434"` to a plain-http address with no port. Typing a bare
    ///    `192.168.1.20` is the whole point: without this it resolves to port 80
    ///    and fails with nothing on screen to explain why. Left alone for
    ///    `https://`, where a bare host means a reverse proxy on 443.
    ///
    /// **This is the preferred entry point for UI forms** where you want to give early visual feedback.
    static func sanitizeAndValidate(_ input: String) -> String? {
        var url = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }

        // A scheme we don't speak is a mistake to report, not one to paper over:
        // blindly prefixing turns "ftp://host" into "http://ftp://host", which
        // parses, passes validation, and quietly points at a host named "ftp".
        if let sep = url.range(of: "://") {
            let scheme = url[url.startIndex..<sep.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
        } else {
            // Auto-correct missing scheme — Ollama speaks plain HTTP on a LAN.
            url = "http://" + url
        }
        // Drop a trailing slash before reasoning about the port, so "1.2.3.4/"
        // doesn't end up as "1.2.3.4/:11434".
        while url.hasSuffix("/") { url = String(url.dropLast()) }

        if let parsed = URL(string: url), parsed.port == nil,
           parsed.scheme == "http", parsed.host?.isEmpty == false {
            url += ":\(defaultOllamaPort)"
        }

        return validateServerURL(url) ? url : nil
    }

    /// Validate a server URL for http/https scheme and non-empty host.
    /// Also rejects suspicious characters that could enable command injection.
    ///
    /// **Validation rules**:
    /// - Scheme must be `http://` or `https://` (no file://, ftp://, etc.).
    /// - Host must be present and non-empty (rejects "http://" with no host).
    /// - No spaces, newlines, or leading dashes in the host (prevents injection).
    /// - Port, if present, is validated as a valid Int (URL(string:) handles this implicitly).
    static func validateServerURL(_ url: String) -> Bool {
        // Guard against crash from malformed URLs — URL(string:) returns nil for invalid input.
        guard let parsed = URL(string: url) else { return false }

        // Scheme check: Ollama only speaks HTTP or HTTPS.
        guard let scheme = parsed.scheme,
              (scheme == "http" || scheme == "https") else { return false }

        // Host must exist and not be an empty string (e.g. rejecting "http://" bare).
        guard let host = parsed.host, !host.isEmpty else { return false }

        // Reject characters that could enable command injection or unexpected behavior.
        guard !host.contains(" "),
              !host.contains("\n"),
              !host.hasPrefix("-") else { return false }

        // Optional port validation: if present, it must be a valid integer.
        // URL.port returns nil for ports outside the valid range, so nil here means bad port.
        if let rawPort = parsed.port, rawPort <= 0 || rawPort > 65535 {
            return false
        }

        return true
    }

    /// Validate a URL and return it if valid, nil otherwise.
    static func validate(_ url: String) -> String? {
        validateServerURL(url) ? url : nil
    }
}
