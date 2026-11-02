/// CI asking for the scheme a build of an app's commit carries, before it
/// builds it (`POST /api/build-scheme`; `applications-server scheme` on the
/// server's Mac). Asked again for the same app and commit under the same
/// release, the answer is the same.
public struct BuildSchemeRequest: Codable, Sendable, Equatable {
    public var bundleID: String
    /// The commit built: its sha, or at least its first seven characters.
    public var commit: String

    public init(bundleID: String, commit: String) {
        self.bundleID = bundleID
        self.commit = commit
    }
}
