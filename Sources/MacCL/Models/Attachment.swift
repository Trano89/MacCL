import Foundation
import AppKit
import UniformTypeIdentifiers

/// A file attached to an outgoing message.
///
/// - `.image`  → sent as an Anthropic `image` content block (base64). Works with
///               vision models (Anthropic, or local vision models via the router).
/// - `.text`   → its contents are embedded inline in the message (works with any
///               model, local included).
/// - `.other`  → referenced by absolute path so the agent can open it with Read.
struct Attachment: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case image, text, other }

    let id = UUID()
    let url: URL
    let filename: String
    let kind: Kind
    let mediaType: String?     // images only, e.g. "image/png"
    let base64: String?        // images only
    let textContent: String?   // text files only
    let byteSize: Int

    static func == (lhs: Attachment, rhs: Attachment) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // Full memberwise init (used by `load`). Declared explicitly so it survives
    // alongside the Codable extension below.
    init(url: URL, filename: String, kind: Kind, mediaType: String?,
         base64: String?, textContent: String?, byteSize: Int) {
        self.url = url
        self.filename = filename
        self.kind = kind
        self.mediaType = mediaType
        self.base64 = base64
        self.textContent = textContent
        self.byteSize = byteSize
    }

    // Anthropic-supported image formats (others are transcoded to PNG).
    private static let directImageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp",
    ]

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf", "swift", "js", "mjs", "cjs", "ts", "tsx",
        "jsx", "py", "rb", "go", "rs", "java", "kt", "kts", "c", "h", "cpp",
        "hpp", "cc", "m", "mm", "cs", "json", "jsonc", "yaml", "yml", "toml",
        "xml", "html", "htm", "css", "scss", "less", "sh", "zsh", "bash", "fish",
        "sql", "csv", "tsv", "log", "env", "ini", "conf", "cfg", "plist",
        "gradle", "properties", "r", "php", "pl", "lua", "dart", "scala", "clj",
        "ex", "exs", "erl", "vue", "svelte", "astro", "tf", "proto", "graphql",
        "dockerfile", "makefile", "gitignore", "editorconfig",
    ]

    private static let maxTextBytes = 512 * 1024
    private static let maxImageBytes = 5 * 1024 * 1024

    /// Inspect the file and build the right kind of attachment. Runs off-main.
    static func load(from url: URL) -> Attachment? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return nil }
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        let isImage = directImageTypes[ext] != nil ||
            ((try? url.resourceValues(forKeys: [.contentTypeKey]))?
                .contentType?.conforms(to: .image) ?? false)
        if isImage, let (b64, mt) = encodeImage(url: url, ext: ext) {
            return Attachment(url: url, filename: name, kind: .image,
                              mediaType: mt, base64: b64, textContent: nil, byteSize: size)
        }

        if (textExtensions.contains(ext) || textExtensions.contains(name.lowercased()) || ext.isEmpty),
           size <= maxTextBytes,
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            return Attachment(url: url, filename: name, kind: .text,
                              mediaType: nil, base64: nil, textContent: text, byteSize: size)
        }

        return Attachment(url: url, filename: name, kind: .other,
                          mediaType: nil, base64: nil, textContent: nil, byteSize: size)
    }

    /// Build an image attachment from raw bytes (clipboard paste, drag of image
    /// data with no file). Normalizes to a supported format and writes a temp
    /// file so the chip thumbnail (which loads from `url`) works.
    static func fromImageData(_ data: Data, suggestedName: String = "collage") -> Attachment? {
        guard let (base64, mediaType, bytes) = normalizeImage(data) else { return nil }
        let ext = mediaType == "image/jpeg" ? "jpg" : (mediaType == "image/gif" ? "gif" : "png")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacCL-paste", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(suggestedName)-\(UUID().uuidString.prefix(8)).\(ext)")
        try? bytes.write(to: url)
        return Attachment(url: url, filename: url.lastPathComponent, kind: .image,
                          mediaType: mediaType, base64: base64, textContent: nil, byteSize: bytes.count)
    }

    /// Keep already-supported formats as-is (within the size cap); otherwise
    /// transcode to PNG. Returns (base64, mediaType, encodedBytes).
    private static func normalizeImage(_ data: Data) -> (String, String, Data)? {
        if let mt = imageMediaType(data), data.count <= maxImageBytes {
            return (data.base64EncodedString(), mt, data)
        }
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              png.count <= maxImageBytes else { return nil }
        return (png.base64EncodedString(), "image/png", png)
    }

    /// Detect an Anthropic-supported image format from magic bytes.
    private static func imageMediaType(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        return nil
    }

    private static func encodeImage(url: URL, ext: String) -> (String, String)? {
        if let mt = directImageTypes[ext],
           let data = try? Data(contentsOf: url), data.count <= maxImageBytes {
            return (data.base64EncodedString(), mt)
        }
        // Transcode HEIC/TIFF/BMP/etc. to PNG.
        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              png.count <= maxImageBytes else { return nil }
        return (png.base64EncodedString(), "image/png")
    }

    // MARK: - Presentation

    var iconName: String {
        switch kind {
        case .image: return "photo"
        case .text: return "doc.text"
        case .other: return "paperclip"
        }
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    // MARK: - Wire format

    /// Anthropic content block(s) representing this attachment in a user message.
    func contentBlocks() -> [[String: Any]] {
        switch kind {
        case .image:
            guard let base64, let mediaType else { return [] }
            return [[
                "type": "image",
                "source": ["type": "base64", "media_type": mediaType, "data": base64],
            ]]
        case .text:
            let body = textContent ?? ""
            let fence = body.contains("```") ? "````" : "```"
            return [[
                "type": "text",
                "text": "Fichier joint « \(filename) » :\n\(fence)\n\(body)\n\(fence)",
            ]]
        case .other:
            return [[
                "type": "text",
                "text": "Fichier joint : \(url.path)\n(utilise l'outil Read pour l'ouvrir si nécessaire)",
            ]]
        }
    }
}

// Codable for history storage. base64 / textContent are intentionally omitted so
// the stored transcript stays small; chips still render from url/filename/kind.
extension Attachment: Codable {
    enum CodingKeys: String, CodingKey { case url, filename, kind, mediaType, byteSize }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        filename = try c.decode(String.self, forKey: .filename)
        kind = try c.decode(Kind.self, forKey: .kind)
        mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType)
        byteSize = try c.decode(Int.self, forKey: .byteSize)
        base64 = nil
        textContent = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encode(filename, forKey: .filename)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(mediaType, forKey: .mediaType)
        try c.encode(byteSize, forKey: .byteSize)
    }
}
