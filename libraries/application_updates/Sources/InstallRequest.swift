import Foundation

/// An app asking Applications on the Mac to install its newest build: one a
/// bundle id (asking again replaces the earlier), taken by Applications
/// when it launches or hears the database changed.
public struct InstallRequest: Sendable, Equatable {
    /// The app to install.
    public var bundleID: String
    /// The version it asked for (the newest Applications had said).
    public var version: String
    public var build: String?
    /// Who asked: the app itself, which quit after asking and is opened
    /// again once the build is in place.
    public var requestedBy: String
    public var requestedAt: Date

    public init(bundleID: String, version: String, build: String?, requestedBy: String, requestedAt: Date) {
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.requestedBy = requestedBy
        self.requestedAt = requestedAt
    }
}
