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
    /// `@unchecked Sendable` is a promise the class has to keep. It didn't:
    /// `discoveredServers` was written from the scanning task while the
    /// main actor read it a few lines above, and `isScanning` was a
    /// check-then-set with nothing between the two — so a network-change scan
    /// landing on top of the periodic one could run a second sweep and write
    /// the dictionary concurrently. Every shared field now sits behind `lock`.
    final class PeriodicScanner: @unchecked Sendable {
        private let lock = NSLock()
        private var timerTask: Task<Void, Never>?
        private let interval: TimeInterval
        private weak var delegate: ServerDiscoveryDelegate?
        /// What the LAST completed scan saw, keyed by URL — used only to tell a
        /// newly-appeared server from one already reported.
        private var _discoveredServers: [String: Server] = [:]
        private var _isScanning = false

        var discoveredServers: [String: Server] {
            lock.lock(); defer { lock.unlock() }
            return _discoveredServers
        }

        /// Claim the right to scan. False when one is already in flight.
        private func beginScan() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if _isScanning { return false }
            _isScanning = true
            return true
        }

        private func endScan() {
            lock.lock(); _isScanning = false; lock.unlock()
        }

        init(interval: TimeInterval = 30, delegate: ServerDiscoveryDelegate?) {
            self.interval = interval
            self.delegate = delegate
        }

        /// Start periodic scanning. Each scan probes localhost + the /28 of every interface.
        func start(configuredServer: String? = nil) {
            stop()
            // Do an immediate first scan, then schedule recurring ones.
            Task { [weak self] in await self?.runScan(configuredServer: configuredServer) }
            let task = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                    await self.runScan(configuredServer: nil)
                }
            }
            lock.lock(); timerTask = task; lock.unlock()
        }

        func stop() {
            lock.lock()
            let task = timerTask
            timerTask = nil
            lock.unlock()
            task?.cancel()
        }

        /// Run a single discovery scan (public for on-demand triggers from network changes).
        func runScan(configuredServer: String?) async {
            guard beginScan() else { return }
            defer { endScan() }
            let newServers = await discover(port: 11434, configured: configuredServer ?? "")
            let now = [String: Server](uniqueKeysWithValues: newServers.map { ($0.url, $0) })

            // Take what the previous scan knew, then publish this one's result.
            // The comparison has to happen against a snapshot: reading the live
            // dictionary from the main actor while this task rewrote it was the
            // race, and it also made "new" depend on when the two interleaved.
            lock.lock()
            let previous = _discoveredServers
            _discoveredServers = now
            lock.unlock()

            guard !newServers.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for server in newServers where previous[server.url] == nil {
                    delegate?.didDiscoverServer(server)
                }
            }
        }
    }

    /// Protocol for receiving periodic discovery callbacks.
    @MainActor
    protocol ServerDiscoveryDelegate: AnyObject {
        func didDiscoverServer(_ server: OllamaDiscovery.Server)
    }

    // MARK: - Local IPv4 interfaces

    /// A local interface: IPv4 address plus the netmask that says how big its
    /// network actually is. The mask is the whole point — guessing the subnet
    /// instead of reading it is how a server at .45 stays invisible forever.
    struct Interface {
        let ip: UInt32
        let mask: UInt32
    }

    static func localIPv4Interfaces() -> [Interface] {
        var result: [Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               let sm = ifa.ifa_netmask, String(cString: ifa.ifa_name) != "lo0" {
                let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                let mask = sm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                // Skip loopback (127/8) and link-local self-assigned (169.254/16).
                let firstOctet = ip >> 24
                let isLinkLocal = (ip >> 16) == 0xA9FE
                if firstOctet != 127, !isLinkLocal, mask != 0 {
                    result.append(Interface(ip: ip, mask: mask))
                }
            }
            ptr = ifa.ifa_next
        }
        return result
    }

    static func ipString(_ v: UInt32) -> String {
        "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }

    /// Every usable host address on `iface`'s network, network and broadcast
    /// excluded. A /16 (or wider) would mean 65k probes, so the sweep is capped
    /// to the /24 around our own address — that's a home LAN in practice.
    static func subnetHosts(_ iface: Interface) -> [String] {
        let mask = max(iface.mask, 0xFFFFFF00 as UInt32)   // never wider than /24
        let network = iface.ip & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [ipString(iface.ip)] }  // /31, /32
        return ((network + 1)...(broadcast - 1)).map(ipString)
    }

    // MARK: - Discovery

    /// Probe localhost + every address on each local interface's own network +
    /// the configured host. Reading the real netmask is what makes a server
    /// anywhere on the LAN discoverable, not just the first sixteen addresses.
    static func discover(port: Int, configured: String) async -> [Server] {
        var targets = Set<String>(["127.0.0.1"])
        if let host = URLComponents(string: configured)?.host { targets.insert(host) }
        for iface in localIPv4Interfaces() {
            targets.formUnion(subnetHosts(iface))
        }

        let hosts = Array(targets)
        var found: [Server] = []
        // A /24 sweep is ~254 probes; most LAN hosts refuse instantly, only truly
        // absent addresses cost the full timeout. Widen the fan-out to match.
        let maxConcurrent = 64
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

        /// Last status handed to the delegate. Touched only from `queue`, which
        /// is serial, so it needs no lock of its own.
        private var lastReachable: Bool?

        func startMonitoring() {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self, weak delegate] path in
                guard let self, let delegate else { return }
                let reachable = path.status == .satisfied
                // Only a real transition is worth reporting. NWPathMonitor
                // fires on every path change — a VPN toggling, Wi-Fi roaming,
                // an interface coming up — and each one made the delegate
                // launch a full /24 sweep. That is the port-scanner behaviour
                // the periodic interval was widened to 300 s to avoid, arriving
                // through the other door.
                guard self.lastReachable != reachable else { return }
                self.lastReachable = reachable
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
