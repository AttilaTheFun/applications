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

    /// Where a device with `installed` stands with the newest build. The
    /// executable's UUID decides where both have one; else the numbers do,
    /// the same numbers counting as the same build.
    public func standing(_ installed: InstalledBuild?) -> InstallStanding {
        guard let latest else { return .upToDate }
        guard let installed else { return .unknown }
        if !installed.executableUUID.isEmpty, let uuid = latest.executableUUID, !uuid.isEmpty {
            if installed.executableUUID == uuid { return .upToDate }
            // An older published build, or numbers that are not newer.
            if builds.dropFirst().contains(where: { $0.executableUUID == installed.executableUUID }) { return .updateAvailable }
            return installed.compareNumbers(to: latest) == .orderedDescending ? .upToDate : .updateAvailable
        }
        return installed.compareNumbers(to: latest) == .orderedAscending ? .updateAvailable : .upToDate
    }

    /// Which of a bundle id's groups of builds (its Alpha's, Beta's,
    /// AdHoc's, Production's, listed apart) holds the build installed, as
    /// one bundle id is one app installed at a time: the one with its
    /// executable, where it says one; else the one of its variant, where it
    /// says; else the one with its numbers; else production's. Nil when
    /// none does (a variant none is of).
    public static func holder(of installed: InstalledBuild, among groups: [AppBuilds]) -> AppBuilds? {
        if !installed.executableUUID.isEmpty,
           let group = groups.first(where: { $0.builds.contains { $0.executableUUID == installed.executableUUID } }) { return group }
        if let variant = installed.variant { return groups.first { $0.builds.contains { $0.variant == variant } } }
        if let group = groups.first(where: { $0.builds.contains { installed.compareNumbers(to: $0) == .orderedSame } }) { return group }
        return groups.first { $0.builds.contains { $0.channel == .production } }
    }

    /// The published build that is the installed one, if it is published.
    public func build(installed: InstalledBuild?) -> Build? {
        guard let installed else { return nil }
        return builds.first { build in
            if !installed.executableUUID.isEmpty, let uuid = build.executableUUID, !uuid.isEmpty { return uuid == installed.executableUUID }
            return installed.compareNumbers(to: build) == .orderedSame
        }
    }
}
