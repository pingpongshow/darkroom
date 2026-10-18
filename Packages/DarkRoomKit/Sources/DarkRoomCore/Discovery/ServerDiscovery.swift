import Foundation
import ImmichAPI
#if canImport(Darwin)
import Darwin
#endif

/// An Immich server found on the local network.
public struct DiscoveredServer: Hashable, Sendable, Identifiable {
    public var url: URL
    public var version: String
    public var id: String { url.absoluteString }
    public var displayName: String {
        let host = url.host() ?? url.absoluteString
        let port = url.port.map { ":\($0)" } ?? ""
        return host + port
    }
}

/// Finds Immich servers automatically.
///
/// Immich doesn't advertise itself (no Bonjour), so discovery probes likely addresses:
/// previously used servers, `immich.local`, and every host on the Mac's local /24 subnet(s), on
/// Immich's common ports. A candidate counts only if it answers Immich's
/// `GET /api/server/ping` (`{"res":"pong"}`) **and** `/api/server/version`.
public struct ServerDiscovery: Sendable {
    /// Ports in the order they are tried (2283 is Immich's default).
    public static let commonPorts = [2283, 8080, 8585, 3001, 80, 8000, 8081, 9000, 2284]
    public static let commonHostnames = ["immich.local", "immich"]

    public var ports: [Int]
    public var extraHosts: [String]
    public var knownServers: [URL]
    public var timeout: TimeInterval
    public var concurrency: Int

    public init(ports: [Int] = ServerDiscovery.commonPorts, extraHosts: [String] = ServerDiscovery.commonHostnames,
                knownServers: [URL] = [], timeout: TimeInterval = 0.8, concurrency: Int = 96) {
        self.ports = ports
        self.extraHosts = extraHosts
        self.knownServers = knownServers
        self.timeout = timeout
        self.concurrency = concurrency
    }

    /// Candidate base URLs, most likely first.
    public func candidates(localSubnets: [IPv4Subnet] = IPv4Subnet.local()) -> [URL] {
        var urls: [URL] = knownServers
        for host in extraHosts {
            for port in ports { urls.append(URL(string: "http://\(host):\(port)")!) }
        }
        let hosts = localSubnets.flatMap(\.scanHosts)
        for port in ports {
            for host in hosts { urls.append(URL(string: "http://\(host):\(port)")!) }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    /// Streams verified servers as they are found; finishes when every candidate was tried.
    public func scan(candidates: [URL]? = nil) -> AsyncStream<DiscoveredServer> {
        let list = candidates ?? self.candidates()
        let timeout = self.timeout
        let concurrency = max(1, self.concurrency)
        return AsyncStream { continuation in
            let task = Task {
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = timeout
                config.timeoutIntervalForResource = timeout * 3
                config.waitsForConnectivity = false
                config.httpMaximumConnectionsPerHost = 2
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }
                var found = Set<String>()
                await withTaskGroup(of: DiscoveredServer?.self) { group in
                    var iterator = list.makeIterator()
                    func addNext() -> Bool {
                        guard let url = iterator.next() else { return false }
                        group.addTask { await Self.probe(url, session: session) }
                        return true
                    }
                    for _ in 0..<concurrency where addNext() {}
                    while let result = await group.next() {
                        if Task.isCancelled { group.cancelAll(); break }
                        if let server = result, found.insert(server.id).inserted {
                            continuation.yield(server)
                        }
                        _ = addNext()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Returns the server if `url` is an Immich server.
    public static func probe(_ url: URL, session: URLSession) async -> DiscoveredServer? {
        let base = url.lastPathComponent == "api" ? url.deletingLastPathComponent() : url
        guard let (data, response) = try? await session.data(from: base.appending(path: "api/server/ping")),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let ping = try? JSONDecoder().decode([String: String].self, from: data), ping["res"] == "pong",
              let (vdata, vresponse) = try? await session.data(from: base.appending(path: "api/server/version")),
              (vresponse as? HTTPURLResponse)?.statusCode == 200,
              let version = try? JSONDecoder().decode(ServerVersionResponseDto.self, from: vdata) else { return nil }
        return DiscoveredServer(url: base, version: "v\(version.major).\(version.minor).\(version.patch)")
    }
}

/// An IPv4 subnet of one of the Mac's network interfaces.
public struct IPv4Subnet: Hashable, Sendable {
    public var interface: String
    public var address: UInt32
    public var netmask: UInt32

    public init(interface: String, address: UInt32, netmask: UInt32) {
        self.interface = interface
        self.address = address
        self.netmask = netmask
    }

    public init?(interface: String, address: String, netmask: String) {
        guard let a = Self.parse(address), let m = Self.parse(netmask) else { return nil }
        self.init(interface: interface, address: a, netmask: m)
    }

    /// Private LAN ranges only (10/8, 172.16/12, 192.168/16). Tailscale/CGNAT (100.64/10),
    /// loopback and link-local are excluded: they're either too large to scan or not a LAN.
    public var isScannablePrivateLAN: Bool {
        let first = address >> 24, second = (address >> 16) & 0xFF
        return first == 10 || (first == 172 && (16...31).contains(second)) || (first == 192 && second == 168)
    }

    /// Hosts to probe: the whole /24 around this Mac (larger subnets are limited to their /24),
    /// excluding the network, broadcast and the Mac's own address.
    public var scanHosts: [String] {
        let mask = max(netmask, 0xFFFF_FF00)
        let network = address & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        return ((network + 1)..<broadcast).filter { $0 != address }.map(Self.format)
    }

    public static func local() -> [IPv4Subnet] {
        var result: [IPv4Subnet] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), let mask = entry.ifa_netmask,
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let subnet = IPv4Subnet(interface: String(cString: entry.ifa_name), address: a, netmask: m)
            if subnet.isScannablePrivateLAN, !result.contains(where: { ($0.address & 0xFFFF_FF00) == (a & 0xFFFF_FF00) }) {
                result.append(subnet)
            }
        }
        return result
    }

    static func parse(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
        return parts.reduce(0) { $0 << 8 | $1 }
    }

    static func format(_ value: UInt32) -> String {
        "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }
}
