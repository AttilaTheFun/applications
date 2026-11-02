import Foundation

/// What Applications writes of an app as it syncs: its newest build here
/// and where that installs from.
public struct LatestBuild: Sendable, Equatable {
    public var bundleID: String
    public var version: String
    public var build: String?
    public var installURL: URL?

    public init(bundleID: String, version: String, build: String?, installURL: URL?) {
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.installURL = installURL
    }
}
