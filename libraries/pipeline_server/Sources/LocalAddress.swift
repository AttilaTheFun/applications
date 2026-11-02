import Foundation

/// One of this computer's IPv4 addresses: on a LAN, or on an overlay
/// network (a tailnet, 100.64.0.0/10), which a phone reaches from
/// anywhere.
public struct LocalAddress: Sendable, Hashable {
    public let ip: String
    public let overlay: Bool

    public init(ip: String, overlay: Bool) {
        self.ip = ip
        self.overlay = overlay
    }

    /// This computer's addresses, LAN first: not loopback, not
    /// link-local (169.254), not a bridge (the network a Mac shares with
    /// its containers and VMs, bridge100, which comes and goes with them,
    /// and is no address a phone reaches), each once.
    public static func current() -> [LocalAddress] {
        var found: [LocalAddress] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  !String(cString: entry.pointee.ifa_name).hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !ip.hasPrefix("169.254."), !found.contains(where: { $0.ip == ip }) else { continue }
            found.append(LocalAddress(ip: ip, overlay: isOverlay(ip)))
        }
        return found.filter { !$0.overlay } + found.filter(\.overlay)
    }

    /// In 100.64.0.0/10, where Tailscale and other overlays put devices.
    public static func isOverlay(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}
