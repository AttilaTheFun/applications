import Foundation

/// Where the server keeps what it keeps: ~/Library/Application Support/
/// Applications, $APPLICATIONS_DATA_DIR (a scratch server beside the real
/// one), or a folder of a test's own.
public struct ServerPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var standard: ServerPaths {
        if let given = ProcessInfo.processInfo.environment["APPLICATIONS_DATA_DIR"], !given.isEmpty {
            return ServerPaths(root: URL(fileURLWithPath: given, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ServerPaths(root: support.appendingPathComponent("Applications", isDirectory: true))
    }

    public var config: URL { root.appendingPathComponent("config.json") }
    public var apnsKey: URL { root.appendingPathComponent("apns.p8") }
    /// The App Store Connect API key notarytool notarizes Mac apps with.
    public var notaryKey: URL { root.appendingPathComponent("notary.p8") }
    /// The provisioning profiles the server signs iPhone apps with, any
    /// file name (each says its bundle id).
    public var profiles: URL { root.appendingPathComponent("profiles", isDirectory: true) }
    public var devices: URL { root.appendingPathComponent("devices.json") }
    public var channels: URL { root.appendingPathComponent("channels.json") }
    public var buildNumbers: URL { root.appendingPathComponent("build-numbers.json") }
    public var appNames: URL { root.appendingPathComponent("apps.json") }
    public var builds: URL { root.appendingPathComponent("builds", isDirectory: true) }
    public var uploads: URL { root.appendingPathComponent("uploads", isDirectory: true) }
    public var tls: URL { root.appendingPathComponent("tls", isDirectory: true) }
    /// The binary the launchd service runs, copied here by `install`.
    public var binary: URL { root.appendingPathComponent("bin/applications-server") }

    /// Makes the folders, readable by this user alone.
    public func prepare() throws {
        for folder in [root, builds, uploads, tls, profiles] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }
}
