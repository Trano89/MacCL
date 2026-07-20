import Foundation
import Combine

/// A persisted conversation (full transcript + metadata).
struct Conversation: Identifiable, Codable {
    let id: String            // == the claude session id (UUID), so it can --resume
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var modelId: String
    var workingDirectory: String
    // Per-conversation launch parameters (optional: older files lack them).
    var permissionMode: String?
    var effort: String?
    /// The Ollama server THIS conversation talks to. A conversation is bound to
    /// its server: if it's down the conversation waits — no silent fallback.
    var serverURL: String?
    /// Extra instructions appended to the system prompt for THIS conversation.
    var instructions: String?
    /// User-defined group name for organizing the sidebar.
    var group: String?
    var items: [ChatItem]
    var totalCostUSD: Double
    // Token accounting (optional: files saved before it existed still decode).
    var contextTokens: Int?
    var totalInputTokens: Int?
    var totalOutputTokens: Int?
}

/// Lightweight metadata for the history list (decoded without the items).
struct ConversationSummary: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var updatedAt: Date
    var modelId: String
    var group: String?
}

/// Stores conversations as one JSON file each under Application Support.
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published private(set) var summaries: [ConversationSummary] = []

    private init() { reload() }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }
    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.conversations, includingPropertiesForKeys: nil)) ?? []
        summaries = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ConversationSummary.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ conversation: Conversation) {
        let url = AppPaths.conversations.appendingPathComponent("\(conversation.id).json")
        do {
            try encoder.encode(conversation).write(to: url, options: .atomic)
        } catch {
            // Swallowing this used to lose conversations with zero trace.
            AppLog.write("store", "save failed for \(conversation.id): \(error.localizedDescription)")
            return
        }
        // Update the one affected summary in place — the old full reload()
        // re-read and re-decoded EVERY conversation file on disk, twice per turn.
        let summary = ConversationSummary(id: conversation.id, title: conversation.title,
                                          updatedAt: conversation.updatedAt,
                                          modelId: conversation.modelId,
                                          group: conversation.group)
        summaries.removeAll { $0.id == summary.id }
        summaries.append(summary)
        summaries.sort { $0.updatedAt > $1.updatedAt }
    }

    func load(_ id: String) -> Conversation? {
        let url = AppPaths.conversations.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Conversation.self, from: data)
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(
            at: AppPaths.conversations.appendingPathComponent("\(id).json"))
        summaries.removeAll { $0.id == id }
    }

    /// Assign (or clear, with nil) a conversation's group.
    func setGroup(_ id: String, group: String?) {
        guard var convo = load(id) else { return }
        convo.group = group?.trimmingCharacters(in: .whitespacesAndNewlines)
        if convo.group?.isEmpty == true { convo.group = nil }
        save(convo)
    }

    /// Distinct group names in use, sorted.
    var groupNames: [String] {
        Array(Set(summaries.compactMap(\.group))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }
}
