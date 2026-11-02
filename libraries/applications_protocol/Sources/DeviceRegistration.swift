/// A device's push token, given to the server so it can tell the device
/// of new builds.
public struct DeviceRegistration: Codable, Sendable, Hashable {
    public var token: String
    /// APNs's service the token is for: "sandbox" (a development-signed
    /// app) or "production".
    public var environment: String
    /// The app's bundle id, which APNs needs as the push's topic.
    public var topic: String
    public var name: String

    public init(token: String, environment: String, topic: String, name: String) {
        self.token = token
        self.environment = environment
        self.topic = topic
        self.name = name
    }
}
