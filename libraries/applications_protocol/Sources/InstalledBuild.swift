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
