import Foundation

/// One published build of an app: what it is, when it came, and the key
/// that its install links carry (iOS asks for the
/// manifest and the app without the app's password, so the links are
/// the permission).
public struct Build: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    /// The app's bundle id: what builds of one app share.
    public var bundleID: String
    public var name: String
    /// CFBundleShortVersionString, and CFBundleVersion.
    public var version: String
    public var buildNumber: String
    /// "ios" for an .ipa, "macos" for a Mac app, "android" for an .apk.
    public var platform: String
    public var published: Date
    /// The .ipa's size in bytes.
    public var size: Int64
    /// What changed, as the publisher said it; may be empty.
    public var notes: String
    /// The build has an icon of its own (`/api/builds/<id>/icon`).
    public var hasIcon: Bool
    /// The install links' key (`/builds/<id>/<key>/…`). Only an
    /// authenticated listing carries it.
    public var downloadKey: String
    /// The app's executable's UUID (`MachOUUID`); nil for a build
    /// published before the server read it.
    public var executableUUID: String?
    /// The URL schemes the app declares (CFBundleURLTypes): how Applications on
    /// the iPhone asks iOS whether it is installed. Nil for a build
    /// published before the server read them.
    public var urlSchemes: [String]?
    /// The build's own scheme, `applications-<release>-build-<n>`
    /// (BuildSchemes): stamped into its Info.plist by CI, or added by the
    /// server to an .ipa that came without one. Applications asks iOS
    /// whether some app opens it, when it is of Applications' own release.
    /// Production builds alone have one: nil for a beta and for a build not
    /// tagged; an older build may carry a scheme of an earlier pool
    /// (`releases-build-N`), which no Applications asks about. (`appScheme`:
    /// an app's own, which builds tagged on 8 October carry; no longer
    /// asked.)
    public var appScheme: String?
    public var buildScheme: String?
    /// An Android build's signing certificate's SHA-256, in lowercase hex
    /// (as `apksigner verify --print-certs` gives it): Android installs
    /// an update only over an app signed with the same certificate.
    public var signer: String?
    /// The app this build is a build of, across platforms ("Visor" for the
    /// iPhone's and the Mac's): as its publisher named it, or nil for the
    /// build's own name (`identity`).
    public var app: String?
    /// A branch's build (its commit, branch and pull request); nil for main's.
    public var origin: BuildOrigin?
    /// Beta, or production when a release published it. Nil in what the
    /// server keeps of a build published before builds had a channel of
    /// their own: its version's, as channels.json says. Every build the server lists says its own.
    public var channel: ReleaseChannel?
    /// Its Info.plist's `BuildVariant` (Alpha, Beta or Production), where it
    /// has one: an Alpha is internal, a Beta for TestFlight, Production the
    /// App Store's. Nil for an app not yet building with one.
    public var buildVariant: String?

    /// Which build it is: its `BuildVariant`, else Production for a
    /// production build and Alpha for any other (main's builds before
    /// variants).
    public var variant: String { buildVariant ?? (channel == .production ? "Production" : "Alpha") }

    public init(id: String, bundleID: String, name: String, version: String, buildNumber: String, platform: String = "ios",
                published: Date, size: Int64, notes: String = "", hasIcon: Bool = false, downloadKey: String = "",
                executableUUID: String? = nil, urlSchemes: [String]? = nil, appScheme: String? = nil, buildScheme: String? = nil,
                signer: String? = nil, app: String? = nil, origin: BuildOrigin? = nil, channel: ReleaseChannel? = nil,
                buildVariant: String? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.buildNumber = buildNumber
        self.platform = platform
        self.published = published
        self.size = size
        self.notes = notes
        self.hasIcon = hasIcon
        self.downloadKey = downloadKey
        self.executableUUID = executableUUID
        self.urlSchemes = urlSchemes
        self.appScheme = appScheme
        self.buildScheme = buildScheme
        self.signer = signer
        self.app = app
        self.origin = origin
        self.channel = channel
        self.buildVariant = buildVariant
    }

    /// The app it is a build of: as published, or its name.
    public var identity: String { identity([:]) }

    /// The app it is a build of: as published, else as the server maps its
    /// bundle id (`names`), else its name. A beta's is its production
    /// app's (`BundleVariant`): mapped by either bundle id, else its name
    /// without the beta's mark ("Visor" for "Visor β").
    public func identity(_ names: [String: String]) -> String {
        app.flatMap { $0.isEmpty ? nil : $0 } ?? names[bundleID] ?? names[productionBundleID]
            ?? BundleVariant.productionName(name, bundleID: bundleID)
    }

    /// The production app's bundle id: its own, or `<id>` for a beta's
    /// `<id>.Beta`.
    public var productionBundleID: String { BundleVariant.productionID(bundleID) }

    /// "0.23 (23)"; "0.38.7" for a build that is a version of its own.
    public var versionTitle: String {
        // From 0.38 a build is a version of its own (MAJOR.MINOR.BUILD): its
        // build number is 1 on Apple's systems, and Android's hidden
        // versionCode is the version as a number (MAJOR×1,000,000 +
        // MINOR×1,000 + BUILD). The version says it all.
        let ownVersion = buildNumber == "1" || buildNumber == Self.versionCode(version).map(String.init)
        return buildNumber.isEmpty || buildNumber == version || (Self.isOwnVersion(version) && ownVersion) ? version : "\(version) (\(buildNumber))"
    }

    /// MAJOR.MINOR.BUILD, each a number.
    static func isOwnVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".")
        return parts.count == 3 && parts.allSatisfy { Int($0) != nil }
    }

    /// Android's versionCode for a MAJOR.MINOR.BUILD version: 0.38.1 is 38001.
    public static func versionCode(_ version: String) -> Int? {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3, parts[1] < 1000, parts[2] < 1000 else { return nil }
        return parts[0] * 1_000_000 + parts[1] * 1_000 + parts[2]
    }
}
