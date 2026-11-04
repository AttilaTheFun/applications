/// An app's builds, newest first.
public struct AppBuilds: Codable, Sendable, Identifiable, Hashable {
    public var bundleID: String
    public var name: String
    public var builds: [Build]

    public var id: String { bundleID }
    public var latest: Build? { builds.first }

    public init(bundleID: String, name: String, builds: [Build]) {
        self.bundleID = bundleID
        self.name = name
        self.builds = builds
    }

    /// Where a device with `installed` stands with the newest build: up to
    /// date when it is the newest (InstalledBuild.isBuild: its numbers, and
    /// its executable and variant where both say), or newer than any
    /// published; else an update is available.
    public func standing(_ installed: InstalledBuild?) -> InstallStanding {
        guard let latest else { return .upToDate }
        guard let installed else { return .unknown }
        if installed.isBuild(latest) { return .upToDate }
        return installed.compareNumbers(to: latest) == .orderedDescending ? .upToDate : .updateAvailable
    }

    /// Which of a bundle id's groups of builds (its Alpha's, Beta's,
    /// AdHoc's, Production's, listed apart) holds the build installed, as
    /// one bundle id is one app installed at a time: the one with the build
    /// itself (InstalledBuild.isBuild); else the one of its variant, where
    /// it says; else the one with its numbers; else production's. Nil when
    /// none does (a variant none is of).
    public static func holder(of installed: InstalledBuild, among groups: [AppBuilds]) -> AppBuilds? {
        if let group = groups.first(where: { $0.builds.contains { installed.isBuild($0) } }) { return group }
        if let variant = installed.variant { return groups.first { $0.builds.contains { $0.variant == variant } } }
        if let group = groups.first(where: { $0.builds.contains { installed.compareNumbers(to: $0) == .orderedSame } }) { return group }
        return groups.first { $0.builds.contains { $0.channel == .production } }
    }

    /// The published build that is the installed one, if it is published
    /// (InstalledBuild.isBuild).
    public func build(installed: InstalledBuild?) -> Build? {
        guard let installed else { return nil }
        return builds.first { installed.isBuild($0) }
    }
}
