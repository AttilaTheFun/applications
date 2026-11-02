/// Where a build came from when it is a branch's, built before it merges
/// (CI's :build:): its commit, its branch, and its pull request. A build
/// with none is main's, or a release's.
public struct BuildOrigin: Codable, Sendable, Equatable, Hashable {
    public var commit: String
    public var branch: String?
    public var pullRequest: Int?

    public init(commit: String, branch: String? = nil, pullRequest: Int? = nil) {
        self.commit = commit
        self.branch = branch
        self.pullRequest = pullRequest
    }
}
