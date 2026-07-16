import Foundation
import Network

/// Discovers Ollama servers reachable at `:11434` — on localhost and across the
/// local subnet (a lightweight LAN scan of the machine's /28).
/// Also provides periodic scanning and network-reachability monitoring.
enum OllamaDiscovery {

    // MARK: - Types

    struct Server: Identifiable, Hashable {
        var id: String { url }
        let url: String
        let host: String       // display host (e.g. "localhost" or "192.168.1.42")
        let modelCount: Int

        var standbyServer: StandbyServer {
            let displayName = (host == "localhost" || host == "127.0.0.1") ? "localhost" : host
            return StandbyServer(name: displayName, url: url)
        }
    }

    /// Background scanner that periodically discovers Ollama servers on port 11434.
    final class PeriodicScanner: @unchecked Sendable {
        private var timerTask: Task<Void, Never>?
        private let interval: TimeInterval
        private weak var delegate: ServerDiscoveryDelegate?
        // All servers found across all scans (keyed by URL).
        private(set) var discoveredServers: [String: Server] = [:]
        private var isScanning = false

        init(interval: TimeInterval = 30, delegate: ServerDiscoveryDelegate?) {
            self.interval = interval
            self.delegate = delegate
        }

        /// Start periodic scanning. Each scan probes localhost + the /28 of every interface.
        func start(configuredServer: String? = nil) {
            stop()
            // Do an immediate first scan, then schedule recurring ones.
            Task { [weak self] in await self?.runScan(configuredServer: configuredServer) }
            timerTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                    await self.runScan(configuredServer: nil)
                }
            }
        }

        func stop() {
            timerTask?.cancel()
            timerTask = nil
        }

        /// Run a single discovery scan (public for on-demand triggers from network changes).
        func runScan(configuredServer: String?) async {
            guard !isScanning else { return }
            isScanning = true
            defer { isScanning = false }
            let newServers = await discover(port: 11434, configured: configuredServer ?? "")
            let now = [String: Server](uniqueKeysWithValues: newServers.map { ($0.url, $0) })

            // Report newly found servers on the main actor.
            if !newServers.isEmpty {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for server in newServers where discoveredServers[server.url] == nil {
                        delegate?.didDiscoverServer(server)
                    }
                }
            }
            // Update discovered servers list on the background task's actor.
            discoveredServers = now
        }
    }

    /// Protocol for receiving periodic discovery callbacks.
    @MainActor
    protocol ServerDiscoveryDelegate: AnyObject {
        func didDiscoverServer(_ server: OllamaDiscovery.Server)
    }

    // MARK: - Local IPv4 addresses

    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                if name != "lo0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host,
                                   socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: host)
                        if !ip.isEmpty, !ip.hasPrefix("169.254"), !ip.hasPrefix("127.") {
                            result.append(ip)
                        }
                    }
                }
            }
            ptr = ifa.ifa_next
        }
        return result
    }

    // MARK: - Discovery

    /// Probe localhost + the /28 of EVERY local interface + the configured host.
    static func discover(port: Int, configured: String) async -> [Server] {
        var targets = Set<String>(["127.0.0.1"])
        if let host = URLComponents(string: configured)?.host { targets.insert(host) }
        for ip in localIPv4Addresses() {
            let parts = ip.split(separator: ".")
            if parts.count == 4 {
                let prefix = parts.prefix(3).joined(separator: ".")
                for i in 1...16 { targets.insert("\(prefix).\(i)") }
            }
        }

        let hosts = Array(targets)
        var found: [Server] = []
        let maxConcurrent = 32
        await withTaskGroup(of: Server?.self) { group in
            var index = 0
            while index < min(maxConcurrent, hosts.count) {
                let h = hosts[index]; index += 1
                group.addTask { await probe(host: h, port: port) }
            }
            while let result = await group.next() {
                if let server = result { found.append(server) }
                if index < hosts.count {
                    let h = hosts[index]; index += 1
                    group.addTask { await probe(host: h, port: port) }
                }
            }
        }
        return found.sorted {
            ($0.host == "localhost" ? "" : $0.host) < ($1.host == "localhost" ? "" : $1.host)
        }
    }

    private static func probe(host: String, port: Int) async -> Server? {
        guard let url = URL(string: "http://\(host):\(port)/api/tags") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.7
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            var count = 0
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = obj["models"] as? [Any] {
                count = models.count
            }
            let display = (host == "127.0.0.1" || host == "localhost") ? "localhost" : host
            return Server(url: "http://\(host):\(port)", host: display, modelCount: count)
        } catch {
            return nil
        }
    }

    // MARK: - Network reachability (Network.framework)

    /// Monitor network changes and trigger a callback when connectivity shifts.
    final class ReachabilityMonitor: @unchecked Sendable {
        private weak var delegate: ReachabilityDelegate?
        private var monitor: NWPathMonitor?
        private let queue = DispatchQueue(label: "com.maccl.ollama-reachability")

        init(delegate: ReachabilityDelegate?) {
            self.delegate = delegate
        }

        func startMonitoring() {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak delegate] path in
                guard let delegate else { return }
                let reachable = path.status == .satisfied
                Task { @MainActor in
                    delegate.didChangeNetworkReachable(reachable)
                }
            }
            monitor.start(queue: queue)
            self.monitor = monitor
        }

        func stopMonitoring() {
            monitor?.cancel()
            monitor = nil
        }
    }

    /// Protocol for receiving reachability callbacks.
    @MainActor
    protocol ReachabilityDelegate: AnyObject {
        func didChangeNetworkReachable(_ reachable: Bool)
    }
}
