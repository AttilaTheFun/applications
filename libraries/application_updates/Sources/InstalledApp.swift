import Foundation

/// The app running: its bundle id, the version it is, and its variant.
public struct InstalledApp: Sendable, Equatable {
    public let bundleID: String
    public let version: String
    public let build: String?
    /// Its Info.plist's `BuildVariant` (Alpha, Beta, AdHoc, Production), if
    /// it says.
    public let variant: String?

    public init(bundleID: String, version: String, build: String?, variant: String? = nil) {
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.variant = variant
    }

    /// The main bundle's id and versions; nil for a process with no bundle id.
    public static func main(_ bundle: Bundle = .main) -> InstalledApp? {
        guard let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        let info = bundle.infoDictionary ?? [:]
        return InstalledApp(bundleID: id, version: info["CFBundleShortVersionString"] as? String ?? "",
                            build: info["CFBundleVersion"] as? String, variant: info["BuildVariant"] as? String)
    }

    public var appVersion: AppVersion { AppVersion(version, build: build) }
}
