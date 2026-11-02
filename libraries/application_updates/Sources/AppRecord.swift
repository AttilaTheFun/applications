import Foundation

/// One app's row in the shared database: the newest build Applications
/// knows of (written by Applications as it syncs with Applications Server)
/// and the build installed (written by the app itself at launch, whichever
/// variant it is: a bundle id is one app installed at a time, so the last
/// launched is the one there). A beta of the old layout (`<id>.Beta`) is a
/// row of its own, as it is an app of its own.
public struct AppRecord: Sendable, Equatable {
    public var bundleID: String
    public var latestVersion: String?
    public var latestBuild: String?
    /// Where the newest build installs from: on an iPhone or an iPad its
    /// over-the-air install link (`itms-services://…`), on a Mac its .zip.
    public var installURL: URL?
    public var installedVersion: String?
    public var installedBuild: String?
    /// The installed build's variant (Alpha, Beta, AdHoc, Production), as
    /// it said; nil for a build that doesn't say, or a library from before
    /// it was recorded (which leaves the last variant written).
    public var installedVariant: String?
    /// When the row last changed.
    public var updatedAt: Date

    public init(bundleID: String, latestVersion: String? = nil, latestBuild: String? = nil, installURL: URL? = nil,
                installedVersion: String? = nil, installedBuild: String? = nil, installedVariant: String? = nil, updatedAt: Date) {
        self.bundleID = bundleID
        self.latestVersion = latestVersion
        self.latestBuild = latestBuild
        self.installURL = installURL
        self.installedVersion = installedVersion
        self.installedBuild = installedBuild
        self.installedVariant = installedVariant
        self.updatedAt = updatedAt
    }

    public var latest: AppVersion? { latestVersion.map { AppVersion($0, build: latestBuild) } }
    public var installed: AppVersion? { installedVersion.map { AppVersion($0, build: installedBuild) } }

    /// The newest build is newer than the one installed.
    public var updateAvailable: Bool {
        guard let latest, let installed else { return false }
        return latest > installed
    }
}
