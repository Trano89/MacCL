import Foundation

/// Model preparation that happens OUTSIDE a turn: loading the weights into the
/// server's memory so the next reply starts hot.
///
/// This used to be fired and forgotten — three separate `Task.detached` calls
/// with no trace anywhere. That is why the app could sit on "Ready" while the
/// GPU spent two minutes loading thirty billion parameters: real work, doing
/// exactly what it should, and no way for the user to know it was happening.
/// Everything routes through here now, so the interface can say so.
@MainActor
final class ModelWarmup: ObservableObject {
    static let shared = ModelWarmup()

    struct Job: Identifiable, Equatable {
        var id: String { model + "@" + server }
        let model: String
        let server: String
        let startedAt: Date
        /// Host alone — the full URL is noise in a status line.
        var host: String { URL(string: server)?.host ?? server }
    }

    @Published private(set) var jobs: [Job] = []

    var isPreparing: Bool { !jobs.isEmpty }
    var current: Job? { jobs.first }

    private init() {}

    /// Load `model` on `server`, visibly. Idempotent: asking again for a pair
    /// already in flight joins the existing job rather than starting a second.
    func start(model: String, server: String) {
        guard !model.isEmpty, !server.isEmpty else { return }
        let job = Job(model: model, server: server, startedAt: Date())
        guard !jobs.contains(where: { $0.id == job.id }) else { return }
        jobs.append(job)
        AppLog.write("warmup", "preparing \(model) on \(job.host)")
        Task { [weak self] in
            await OllamaClient.warmUp(model: model, baseURL: server)
            self?.finish(job.id)
        }
    }

    private func finish(_ id: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        let seconds = Int(Date().timeIntervalSince(jobs[idx].startedAt))
        AppLog.write("warmup", "ready \(jobs[idx].model) in \(seconds)s")
        jobs.remove(at: idx)
    }
}
