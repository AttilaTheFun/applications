import Foundation

/// The build installed of an app, as far as is known: its version
/// numbers, and its executable's UUID (`MachOUUID`), which tells builds
/// with the same numbers apart. The Mac app reads it from the app in
/// /Applications; Applications on the iPhone knows its own.
public struct InstalledBuild: Codable, Sendable, Hashable {
    public var bundleID: String
    public var version: String
    public var buildNumber: String
    /// Empty when the app did not say.
    public var executableUUID: String
    /// Its `BuildVariant` (Alpha, Beta, AdHoc, Production), where it says:
    /// which of an app's builds of one bundle id it is.
    public var variant: String?

    public init(bundleID: String, version: String, buildNumber: String, executableUUID: String = "", variant: String? = nil) {
        self.bundleID = bundleID
        self.version = version
        self.buildNumber = buildNumber
        self.executableUUID = executableUUID
        self.variant = variant
    }

    /// Newer, older or the same numbers as `build`: the version
    /// (CFBundleShortVersionString), then the build number, each compared
    /// part by number ("0.10" after "0.9").
    public func compareNumbers(to build: Build) -> ComparisonResult {
        let byVersion = Self.compare(version, build.version)
        return byVersion == .orderedSame ? Self.compare(buildNumber, build.buildNumber) : byVersion
    }

    /// Whether this is `build`: the same numbers, and the same executable
    /// and variant where both say theirs. The executable alone does not
    /// tell: a build of a commit that changed nothing of the app links the
    /// same executable as the one before it (Bazel's builds are
    /// reproducible), and a production build promoted from an Alpha keeps
    /// the Alpha's; their numbers and variants tell them apart.
    public func isBuild(_ build: Build) -> Bool {
        guard compareNumbers(to: build) == .orderedSame else { return false }
        if !executableUUID.isEmpty, let uuid = build.executableUUID, !uuid.isEmpty, uuid != executableUUID { return false }
        if let variant, variant != build.variant { return false }
        return true
    }

    static func compare(_ left: String, _ right: String) -> ComparisonResult {
        let a = left.split(separator: ".").map { Int($0) ?? 0 }
        let b = right.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
