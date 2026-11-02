/// The build number a commit's build of an app's version takes, kept from
/// the moment CI numbers it (before it is built), so every build of the
/// commit has the one number. (`GET /api/build-number?commit=`.)
public struct BuildNumber: Codable, Sendable, Equatable, Hashable {
    public var app: String
    public var version: String
    public var build: Int
    public var commit: String

    public init(app: String, version: String, build: Int, commit: String) {
        self.app = app
        self.version = version
        self.build = build
        self.commit = commit
    }

    /// "0.35 (21)"; "0.38.7" for a build that is a version of its own
    /// (MAJOR.MINOR.BUILD, build number 1).
    public var title: String {
        version.split(separator: ".").count == 3 && (build == 1 || build == Build.versionCode(version)) ? version : "\(version) (\(build))"
    }
}
