import Foundation

/// Discovers Ollama servers reachable at `:11434` — on localhost and across the
/// local subnet (a lightweight LAN scan of the machine's /24).
enum OllamaDiscovery {
    struct Server: Identifiable, Hashable {
        var id: String { url }
        let url: String
        let host: String       // display host (e.g. "localhost" or "192.168.1.42")
        let modelCount: Int
    }

    /// All the machine's IPv4 addresses (every interface: Ethernet, Wi-Fi,
    /// bridges…) so we can scan every subnet this Mac is connected to.
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

    /// Probe localhost + the /24 of EVERY local interface + the configured host.
    static func discover(port: Int, configured: String) async -> [Server] {
        var targets = Set<String>(["127.0.0.1"])
        if let host = URLComponents(string: configured)?.host { targets.insert(host) }
        for ip in localIPv4Addresses() {
            let parts = ip.split(separator: ".")
            if parts.count == 4 {
                let prefix = parts.prefix(3).joined(separator: ".")
                for i in 1...254 { targets.insert("\(prefix).\(i)") }
            }
        }

        let hosts = Array(targets)
        var found: [Server] = []
        let maxConcurrent = 48
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
            // localhost first, then by host
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
}
