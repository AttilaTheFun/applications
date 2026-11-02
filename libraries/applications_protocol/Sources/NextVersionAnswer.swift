/// The version a build takes (`POST /api/next-version`): MAJOR.MINOR.BUILD,
/// with build number 1.
public struct NextVersionAnswer: Codable, Sendable, Equatable {
    public var version: String

    public init(version: String) { self.version = version }
}
