/// The server saying who it is: what any path to it answers, before a
/// password, so the app can tell which paths reach which server.
public struct Hello: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// Every address it is reached at (https://host:port), LAN first.
    public var addresses: [String]
    public var version: String
    /// Which kind of server it is ("applications"), so an app given another
    /// server's code can say so; nil from a server before it said.
    public var kind: String?

    public init(id: String, name: String, addresses: [String], version: String, kind: String? = nil) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.version = version
        self.kind = kind
    }
}
