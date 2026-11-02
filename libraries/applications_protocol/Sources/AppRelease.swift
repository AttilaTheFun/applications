/// An app, across its platforms, and its beta beside its production (one
/// app, `BundleVariant`): its builds from main and from releases, and its
/// pull requests' builds.
public struct AppRelease: Codable, Sendable, Identifiable, Equatable {
    /// What its builds are published under ("Visor").
    public var app: String
    /// A build whose icon stands for the app.
    public var iconBuild: String?
    /// Its builds on every platform, newest first, each on its channel:
    /// production, published by a release, and beta, main's.
    public var builds: [Build]
    /// Its open pull requests' builds, the newest pull request first; nil
    /// from a server before it kept them.
    public var pullRequests: [PullRequestRelease]?

    public var id: String { app }

    public init(app: String, iconBuild: String?, builds: [Build], pullRequests: [PullRequestRelease]? = nil) {
        self.app = app
        self.iconBuild = iconBuild
        self.builds = builds
        self.pullRequests = pullRequests
    }

    /// Its production builds, and its betas (a build that does not say
    /// is a beta), newest first.
    public var production: [Build] { builds.filter { $0.channel == .production } }
    public var beta: [Build] { builds.filter { $0.channel != .production } }

    /// Every build of the app on a platform, newest first.
    public func builds(on platform: String) -> [Build] {
        builds.filter { $0.platform == platform }
    }
}
