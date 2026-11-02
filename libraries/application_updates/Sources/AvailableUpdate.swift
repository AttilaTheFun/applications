import Foundation

/// A newer build of the running app than the one installed, as Applications
/// last said: what its notification offers, and what installing it takes.
public struct AvailableUpdate: Sendable, Equatable {
    public var bundleID: String
    public var version: String
    public var build: String?
    /// The over-the-air install link on an iPhone or an iPad; the build's
    /// .zip on a Mac (what an update handler is given).
    public var installURL: URL?
    public var installedVersion: String
    public var installedBuild: String?

    public init(bundleID: String, version: String, build: String?, installURL: URL?, installedVersion: String, installedBuild: String?) {
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.installURL = installURL
        self.installedVersion = installedVersion
        self.installedBuild = installedBuild
    }

    public var latest: AppVersion { AppVersion(version, build: build) }
    public var installed: AppVersion { AppVersion(installedVersion, build: installedBuild) }

    /// The update's identity: one notification for it a process.
    var key: String { "\(bundleID) \(version) \(build ?? "")" }

    // MARK: In a notification

    private static let prefix = "applicationUpdates."

    /// The update as a notification's user info carries it.
    public var userInfo: [String: String] {
        var info = [Self.prefix + "bundleID": bundleID, Self.prefix + "version": version, Self.prefix + "installedVersion": installedVersion]
        info[Self.prefix + "build"] = build
        info[Self.prefix + "installURL"] = installURL?.absoluteString
        info[Self.prefix + "installedBuild"] = installedBuild
        return info
    }

    /// The update a notification's user info carries; nil for any other
    /// notification's.
    public init?(userInfo: [AnyHashable: Any]) {
        func value(_ key: String) -> String? { userInfo[Self.prefix + key] as? String }
        guard let bundleID = value("bundleID"), let version = value("version"), let installedVersion = value("installedVersion") else {
            return nil
        }
        self.init(bundleID: bundleID, version: version, build: value("build"), installURL: value("installURL").flatMap(URL.init(string:)),
                  installedVersion: installedVersion, installedBuild: value("installedBuild"))
    }
}
