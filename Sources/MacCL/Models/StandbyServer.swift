import Foundation

/// A saved Ollama server that can be used as a standby backend.
struct StandbyServer: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    let url: String

    init(id: String = UUID().uuidString, name: String, url: String) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespaces)
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Codable (preserve 'id' across encode/decode cycles)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)   // keep persisted ID
        self.name = try container.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespaces)
        self.url = try container.decode(String.self, forKey: .url).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Display host from the URL.
    var displayHost: String {
        (URLComponents(string: url)?.host ?? url).replacingOccurrences(of: ":11434", with: "")
    }

    // MARK: - Codable helpers for AppSettings persistence

    private enum CodingKeys: String, CodingKey {
        case id, name, url
    }

    static func encodeArray(_ array: [StandbyServer]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(array))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    static func decodeArray(from raw: String) -> [StandbyServer] {
        guard let data = raw.data(using: .utf8), !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return (try? JSONDecoder().decode([StandbyServer].self, from: data)) ?? []
    }
}
