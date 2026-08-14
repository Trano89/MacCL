import Foundation
import Network

/// A loopback HTTP front-end that lets ONE `claude` process reach SEVERAL Ollama
/// machines.
///
/// Why it has to exist: a process has exactly one `ANTHROPIC_BASE_URL`. Every
/// request a turn makes — the main loop and every sub-agent — goes to that one
/// address. So "run this sub-agent on the machine with the big GPU" is not a
/// setting anyone can flip; something has to read each request and send it
/// somewhere else.
///
/// That something is deliberately as thin as possible. It does not translate a
/// protocol (Ollama serves the Anthropic Messages API itself — that is why the
/// old LiteLLM bridge could be deleted), it does not retry, it does not cache,
/// and it never invents a destination: it reads the `model` field, and
///
/// - `qwen3-coder:30b@nas`  → strip `@nas`, send to the server named "nas",
///                            with `model` rewritten to `qwen3-coder:30b`
/// - `qwen3-coder:30b`      → send to the conversation's own server, untouched
///
/// so a request can only ever land on a machine the user named. An unknown
/// server name is a hard 502 with an explanatory body, never a silent fallback
/// to the default upstream — that is the one behaviour this project has
/// consistently refused (see the removal of hidden routing in 028651d).
///
/// Concurrency: only *routed* requests are gated, one semaphore per named
/// machine. Traffic to the conversation's own server is left alone because the
/// CLI already caps it (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`), and gating the
/// main loop here would stall the conversation behind its own sub-agents.
@MainActor
final class AgentRouter {
    static let shared = AgentRouter()

    /// Where requests go, resolved once per turn from the conversation's server
    /// and the agent definitions.
    struct Route: Sendable {
        /// Upstream for models with no `@server` suffix.
        var defaultUpstream: String
        /// Server name → base URL, from the standby list.
        var byServerName: [String: String]
        /// Max simultaneous in-flight requests per named machine.
        var maxConcurrentPerServer: Int
    }

    private var core: RouterCore?
    /// The loopback port the router listens on, once started.
    private(set) var port: UInt16?

    var isRunning: Bool { port != nil }

    private init() {}

    /// Start (or re-point) the router. Returns the base URL `claude` should use.
    /// Re-pointing an already-running router keeps the port, so a session that
    /// changes server mid-conversation doesn't need relaunching.
    @discardableResult
    func start(route: Route) async throws -> String {
        // `core` and `port` are set together and cleared together, but reading
        // them as two independent optionals invited a "re-pointed, returned
        // empty string" path that would have set ANTHROPIC_BASE_URL="" — a
        // session pointed at nothing. Require both, or start fresh.
        if let core, let port {
            await core.update(route: route)
            AppLog.info("router", "re-pointed: default=\(route.defaultUpstream) "
                        + "servers=\(route.byServerName.keys.sorted().joined(separator: ","))")
            return Self.address(port: port)
        }
        stop()   // a half-built router from a failed start must not linger
        let core = RouterCore(route: route)
        let bound = try await core.start()
        self.core = core
        self.port = bound
        AppLog.info("router", "listening on 127.0.0.1:\(bound) default=\(route.defaultUpstream) "
                    + "servers=\(route.byServerName.keys.sorted().joined(separator: ","))")
        return Self.address(port: bound)
    }

    private static func address(port: UInt16) -> String { "http://127.0.0.1:\(port)" }

    func stop() {
        core?.stop()
        core = nil
        port = nil
        AppLog.info("router", "stopped")
    }
}

// MARK: - The socket side

/// Off-main-actor half: the listener, the connections, and the relay.
private final class RouterCore: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "maccl.router", attributes: .concurrent)
    private let state = RouterState()
    private let hub = RelayHub()
    private let session: URLSession

    init(route: AgentRouter.Route) {
        let config = URLSessionConfiguration.ephemeral
        // A cold 30B answering a long agentic turn: the ceiling has to be well
        // past anything a model will realistically take, or the router becomes
        // the thing that kills the turn.
        config.timeoutIntervalForRequest = 900
        config.timeoutIntervalForResource = 3600
        config.httpMaximumConnectionsPerHost = 16
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // ONE session for every relayed request: a session per request would
        // give each its own connection pool and worker threads, which with a
        // fan-out of sub-agents is exactly the wrong direction.
        session = URLSession(configuration: config, delegate: hub, delegateQueue: nil)
        Task { await state.update(route: route) }
    }

    func update(route: AgentRouter.Route) async {
        await state.update(route: route)
    }

    /// Bind an ephemeral loopback port. Loopback-only is enforced by the
    /// parameters, not by a check later: this proxy carries the user's whole
    /// conversation and must not be reachable from the network.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OneShot()
            listener.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    guard let p = listener.port?.rawValue else {
                        if resumed.claim() {
                            continuation.resume(throwing: RouterError.noPort)
                        }
                        return
                    }
                    if resumed.claim() { continuation.resume(returning: p) }
                case .failed(let error), .waiting(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        session.invalidateAndCancel()
    }

    // MARK: Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(on: conn, buffer: Data())
    }

    /// Accumulate until the headers are complete, then the declared body length.
    private func receiveRequest(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil { conn.cancel(); return }
            var buffer = buffer
            if let data, !data.isEmpty { buffer.append(data) }

            guard let request = HTTPRequest.parse(buffer) else {
                if isComplete { conn.cancel(); return }
                // Refuse to grow without bound on a client that never finishes.
                if buffer.count > 64 * 1024 * 1024 { conn.cancel(); return }
                self.receiveRequest(on: conn, buffer: buffer)
                return
            }
            Task { await self.handle(request, on: conn) }
        }
    }

    private func handle(_ request: HTTPRequest, on conn: NWConnection) async {
        let decision = await state.route(for: request)

        guard case .forward(let upstream, let body, let serverLabel) = decision else {
            if case .unknownServer(let name) = decision {
                AppLog.warn("router", "no server named '\(name)' — refusing to guess")
                send(status: 502, body: """
                    {"type":"error","error":{"type":"invalid_request_error",\
                    "message":"MacCL: no Ollama server named '\(name)' is configured. \
                    Add it in the server list, or remove the @\(name) suffix from the agent's model."}}
                    """, on: conn)
            } else {
                send(status: 400, body: "{\"type\":\"error\",\"error\":{\"message\":\"bad request\"}}", on: conn)
            }
            return
        }

        // Only routed traffic is gated — see the type comment.
        var slot: RouterState.Slot?
        if let serverLabel { slot = await state.acquire(server: serverLabel) }
        defer { slot?.release() }

        guard let url = URL(string: upstream.trimmingTrailingSlash + request.path) else {
            send(status: 502, body: "{\"error\":\"bad upstream\"}", on: conn)
            return
        }
        var upstreamRequest = URLRequest(url: url)
        upstreamRequest.httpMethod = request.method
        upstreamRequest.httpBody = body.isEmpty ? nil : body
        for (k, v) in request.headers {
            let lower = k.lowercased()
            // Host and framing headers describe the hop we're replacing.
            guard !["host", "content-length", "connection", "transfer-encoding",
                    "accept-encoding"].contains(lower) else { continue }
            upstreamRequest.setValue(v, forHTTPHeaderField: k)
        }
        if !body.isEmpty {
            upstreamRequest.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }

        await relay(upstreamRequest, to: conn)
    }

    /// Stream the upstream response back as it arrives. Chunked framing plus
    /// `Connection: close`: the turn is a server-sent-event stream that must
    /// reach the CLI token by token, and buffering it here would undo the whole
    /// point of streaming.
    private func relay(_ request: URLRequest, to conn: NWConnection) async {
        await hub.perform(request, session: session, connection: conn)
    }

    private func send(status: Int, body: String, on conn: NWConnection) {
        let payload = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(status == 502 ? "Bad Gateway" : "Bad Request")\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + payload,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    enum RouterError: Error { case noPort }
}

/// One-shot guard so a listener that reports `.ready` then `.failed` cannot
/// resume the same continuation twice (a crash, not an error).
private final class OneShot: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - Routing state

/// The mutable half, isolated so the route can be re-pointed mid-flight.
private actor RouterState {
    private var route = AgentRouter.Route(defaultUpstream: "", byServerName: [:],
                                          maxConcurrentPerServer: 1)
    private var inFlight: [String: Int] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    enum Decision {
        case forward(upstream: String, body: Data, serverLabel: String?)
        case unknownServer(String)
        case bad
    }

    func update(route: AgentRouter.Route) {
        self.route = route
    }

    /// Decide where a request goes, rewriting the model when it carries a
    /// routing suffix. Anything that isn't a JSON body with a `model` string
    /// (e.g. `/api/tags` probes) is passed straight through to the default.
    func route(for request: HTTPRequest) -> Decision {
        guard !request.body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let rawModel = object["model"] as? String else {
            return .forward(upstream: route.defaultUpstream, body: request.body, serverLabel: nil)
        }

        let (model, serverName) = AgentDefinition.splitModelField(rawModel)
        guard !serverName.isEmpty else {
            return .forward(upstream: route.defaultUpstream, body: request.body, serverLabel: nil)
        }
        guard let upstream = route.byServerName[serverName] else {
            return .unknownServer(serverName)
        }

        var rewritten = object
        rewritten["model"] = model
        guard let body = try? JSONSerialization.data(withJSONObject: rewritten) else { return .bad }
        return .forward(upstream: upstream, body: body, serverLabel: serverName)
    }

    // MARK: Per-server concurrency

    func acquire(server: String) async -> Slot {
        let cap = max(1, route.maxConcurrentPerServer)
        while (inFlight[server] ?? 0) >= cap {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters[server, default: []].append(c)
            }
        }
        inFlight[server, default: 0] += 1
        return Slot(server: server, state: self)
    }

    fileprivate func release(server: String) {
        inFlight[server] = max(0, (inFlight[server] ?? 1) - 1)
        if var queued = waiters[server], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[server] = queued
            next.resume()
        }
    }

    /// Releases exactly once, whatever path the request leaves by.
    final class Slot: @unchecked Sendable {
        private let server: String
        private weak var state: RouterState?
        private var released = false
        private let lock = NSLock()

        init(server: String, state: RouterState) {
            self.server = server
            self.state = state
        }

        func release() {
            lock.lock()
            if released { lock.unlock(); return }
            released = true
            lock.unlock()
            let server = self.server
            Task { [state] in await state?.release(server: server) }
        }

        deinit { release() }
    }
}

// MARK: - Minimal HTTP request parsing

/// Just enough HTTP/1.1 to relay a request: the CLI is the only client, it
/// always sends a Content-Length body, and anything unrecognised is passed
/// through rather than interpreted.
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ buffer: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        guard let headText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound],
                                    encoding: .utf8) else { return nil }
        var lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        let declared = headers.first { $0.key.lowercased() == "content-length" }
            .flatMap { Int($0.value) } ?? 0
        let bodyStart = headerEnd.upperBound
        let available = buffer.count - (bodyStart - buffer.startIndex)
        guard available >= declared else { return nil }   // wait for the rest

        let bodyEnd = buffer.index(bodyStart, offsetBy: declared)
        return HTTPRequest(method: parts[0], path: parts[1], headers: headers,
                           body: Data(buffer[bodyStart..<bodyEnd]))
    }
}

// MARK: - Streaming relay

/// Pushes each upstream response to its client as the bytes land, for every
/// in-flight request at once.
///
/// A delegate rather than `URLSession.bytes` on purpose: iterating an
/// `AsyncBytes` one `UInt8` at a time turns a megabyte of SSE into a million
/// awaits. One hub for the whole router rather than one object per request, so
/// twenty sub-agents streaming at once share a single connection pool.
private final class RelayHub: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Everything a single in-flight relay needs, keyed by task identifier —
    /// unique among the live tasks of one session.
    private final class Pending {
        let connection: NWConnection
        var wroteHead = false
        var continuation: CheckedContinuation<Void, Never>?
        init(connection: NWConnection, continuation: CheckedContinuation<Void, Never>?) {
            self.connection = connection
            self.continuation = continuation
        }
    }

    private var pending: [Int: Pending] = [:]
    private let lock = NSLock()

    private func entry(_ id: Int) -> Pending? {
        lock.lock(); defer { lock.unlock() }
        return pending[id]
    }

    /// Run one request to completion, streaming it to `connection` as it comes.
    func perform(_ request: URLRequest, session: URLSession, connection: NWConnection) async {
        let task = session.dataTask(with: request)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            pending[task.taskIdentifier] = Pending(connection: connection, continuation: c)
            lock.unlock()
            task.resume()
        }
    }

    /// Resume the caller exactly once and forget the request.
    private func finish(_ id: Int) {
        lock.lock()
        let entry = pending.removeValue(forKey: id)
        let continuation = entry?.continuation
        entry?.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let entry = entry(dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        let http = response as? HTTPURLResponse
        var head = "HTTP/1.1 \(http?.statusCode ?? 200) OK\r\n"
        for (key, value) in (http?.allHeaderFields ?? [:]) {
            let name = String(describing: key)
            // Framing is ours to redo: the upstream's belongs to the hop we replaced.
            guard !["Content-Length", "Transfer-Encoding", "Connection", "Content-Encoding"]
                .contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            head += "\(name): \(String(describing: value))\r\n"
        }
        head += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        entry.wroteHead = true
        entry.connection.send(content: Data(head.utf8), completion: .idempotent)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty, let entry = entry(dataTask.taskIdentifier) else { return }
        var chunk = Data(String(format: "%X\r\n", data.count).utf8)
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        entry.connection.send(content: chunk, completion: .idempotent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        guard let entry = entry(id) else { return }
        let connection = entry.connection

        // Nothing was sent yet, so a real HTTP error still fits on the wire —
        // and an error `claude` can read beats a socket that just closes.
        if let error, !entry.wroteHead {
            let message = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
            let payload = Data("""
                {"type":"error","error":{"type":"api_error","message":"MacCL router: \(message)"}}
                """.utf8)
            var head = "HTTP/1.1 502 Bad Gateway\r\n"
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + payload,
                            completion: .contentProcessed { [weak self] _ in
                                connection.cancel()
                                self?.finish(id)
                            })
            return
        }
        // Terminating zero-length chunk, then close.
        connection.send(content: Data("0\r\n\r\n".utf8),
                        completion: .contentProcessed { [weak self] _ in
                            connection.cancel()
                            self?.finish(id)
                        })
    }
}
