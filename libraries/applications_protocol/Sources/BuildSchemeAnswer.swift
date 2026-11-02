/// The scheme CI stamps into a production build's Info.plist
/// (BuildSchemes), under the server's current release. No scheme for
/// Applications itself, which needs none, nor for a beta's bundle id
/// (`<id>.Beta`), which is never asked about: nothing to stamp, and no
/// number given.
public struct BuildSchemeAnswer: Codable, Sendable, Equatable {
    /// The server's current release: Applications', MAJOR.MINOR.
    public var release: String
    /// "applications-0.6-build-3"; nil for Applications and for a beta.
    public var scheme: String?

    public init(release: String, scheme: String?) {
        self.release = release
        self.scheme = scheme
    }
}
