import Foundation

/// Minimal client for a local Ollama server.
enum OllamaClient {
    struct Model: Decodable {
        let name: String
        let details: Details?
        struct Details: Decodable {
            let parameterSize: String?
            enum CodingKeys: String, CodingKey { case parameterSize = "parameter_size" }
        }
    }

    private struct TagsResponse: Decodable { let models: [Model] }

    /// Returns discovered models, or an empty list if the server is unreachable.
    static func listModels(baseURL: String) async -> [LLMModel] {
        guard let url = URL(string: baseURL.trimmingTrailingSlash + "/api/tags") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            return decoded.models.map { model in
                LLMModel.ollama(model.name)
            }
        } catch {
            return []
        }
    }

    /// True if an Ollama server responds at the given base URL.
    static func isReachable(baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL.trimmingTrailingSlash + "/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

private extension String {
    var trimmingTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
