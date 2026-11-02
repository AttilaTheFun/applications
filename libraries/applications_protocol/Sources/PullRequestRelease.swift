/// A pull request's builds of an app, on every platform, newest first:
/// what its branch's commits built, to try before it merges.
public struct PullRequestRelease: Codable, Sendable, Identifiable, Equatable {
    public var number: Int
    public var branch: String?
    public var builds: [Build]

    public var id: Int { number }

    public init(number: Int, branch: String?, builds: [Build]) {
        self.number = number
        self.branch = branch
        self.builds = builds
    }
}
