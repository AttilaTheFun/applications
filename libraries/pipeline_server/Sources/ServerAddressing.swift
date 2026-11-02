/// Where a server is reached: the names its certificate carries, and the
/// addresses it tells its clients.
public enum ServerAddressing {
    /// The names the HTTPS certificate must carry, for these addresses.
    public static func certificateNames(_ local: [LocalAddress], hostName: String) -> [String] {
        var names = local.map(\.ip) + ["127.0.0.1", "localhost"]
        if !hostName.isEmpty { names.append(hostName) }
        return names
    }

    /// The addresses told to clients: each LAN and tailnet address, LAN
    /// first, and the computer's .local name after the LAN's — what finds
    /// it at home whatever address its router gives it next.
    public static func addresses(_ local: [LocalAddress], hostName: String, port: UInt16) -> [String] {
        let ips = local.map { "https://\($0.ip):\(port)" }
        guard hostName.hasSuffix(".local") else { return ips }
        let lan = local.filter { !$0.overlay }.count
        return Array(ips.prefix(lan)) + ["https://\(hostName):\(port)"] + Array(ips.dropFirst(lan))
    }
}
