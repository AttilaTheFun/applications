import Foundation

/// A provisioning profile from the server's profiles/ folder, as it says
/// of itself: the bundle id it is for, its kind, its team, the certificates
/// it names and the entitlements it allows. Its devices are never read out.
struct ProvisioningProfile {
    enum Kind: String, CaseIterable {
        /// An Apple Development certificate's, listing devices: betas'.
        case development
        /// An Apple Distribution certificate's, listing devices: production
        /// builds installed over the air.
        case adHoc = "ad hoc"
        /// For the App Store and TestFlight, which install nothing over the
        /// air: not used yet.
        case appStore = "App Store"
        /// An enterprise team's, for every device.
        case enterprise
        /// A Mac app's Developer ID profile, for the entitlements Apple
        /// restricts.
        case developerID = "Developer ID"
    }

    var file: URL
    var name: String
    /// The bundle id, without the team's prefix; "*" or "<prefix>.*" for a
    /// wildcard profile, which is never used.
    var bundleID: String
    var team: String
    /// What its application identifiers begin with: the team's, as a rule.
    var prefix: String
    var kind: Kind
    /// "iOS", "OSX": the platforms it is for.
    var platforms: [String]
    /// The SHA-1s of the certificates it names, in uppercase hex, as an
    /// identity's (`SigningIdentity.sha1`).
    var certificates: Set<String>
    /// The entitlements it allows, wildcards and all.
    var entitlements: [String: Any]
    var expires: Date

    var isMac: Bool { platforms.contains("OSX") }

    /// A profile's property list (`CodeSigning.profile` opens its
    /// envelope), or nil when it is not one.
    init?(file: URL, plist: Data) {
        guard let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let entitlements = info["Entitlements"] as? [String: Any],
              let identifier = (entitlements["application-identifier"] ?? entitlements["com.apple.application-identifier"]) as? String,
              let expires = info["ExpirationDate"] as? Date else { return nil }
        let prefix = (info["ApplicationIdentifierPrefix"] as? [String])?.first
            ?? identifier.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        guard identifier.hasPrefix(prefix + ".") else { return nil }
        self.file = file
        name = info["Name"] as? String ?? file.lastPathComponent
        bundleID = String(identifier.dropFirst(prefix.count + 1))
        team = (info["TeamIdentifier"] as? [String])?.first ?? prefix
        self.prefix = prefix
        platforms = info["Platform"] as? [String] ?? ["iOS"]
        certificates = Set((info["DeveloperCertificates"] as? [Data] ?? []).map(SigningIdentity.sha1(of:)))
        self.entitlements = entitlements
        self.expires = expires
        let devices = info["ProvisionedDevices"] != nil
        let everyDevice = info["ProvisionsAllDevices"] as? Bool == true
        let debuggable = (entitlements["get-task-allow"] ?? entitlements["com.apple.security.get-task-allow"]) as? Bool == true
        if everyDevice {
            kind = platforms.contains("OSX") ? .developerID : .enterprise
        } else if devices {
            kind = debuggable ? .development : .adHoc
        } else {
            kind = .appStore
        }
    }
}

/// The profiles in the data folder's profiles/, read by what each says of
/// itself, whatever its file is named (`<bundle id>.mobileprovision` reads
/// best; `<bundle id>.adhoc.mobileprovision` beside it; a Mac app's
/// `<bundle id>.provisionprofile`). Copied there by hand from the team's
/// account: Xcode's (~/Library/Developer/Xcode/UserData/Provisioning
/// Profiles), or downloaded.
struct ProfileFolder: Sendable {
    let folder: URL
    let tools: any CodeSigning

    /// Every profile there, the expired ones too.
    func all() -> [ProvisioningProfile] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["mobileprovision", "provisionprofile"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.compactMap { file in (try? tools.profile(file)).flatMap { ProvisioningProfile(file: file, plist: $0) } }
    }

    /// The kinds of profile, best first, that sign an iPhone app's build of
    /// each kind: a beta's development; production's ad hoc, else
    /// enterprise, else development, as a beta's (over the air to the
    /// team's devices, for now; the App Store's come with TestFlight).
    static func kinds(for signing: SigningKind) -> [ProvisioningProfile.Kind] {
        switch signing {
        case .development: [.development]
        case .production: [.adHoc, .enterprise, .development]
        }
    }

    /// The profiles an iPhone app's bundles (the app's, and its
    /// extensions') are signed with, by bundle id: all of one kind, the
    /// best kind that has one for every bundle id, so the app is signed
    /// with one certificate throughout. Refused, naming the first bundle id
    /// without one, when not even the last kind has one for each.
    func iPhoneProfiles(for bundleIDs: [String], signing: SigningKind, now: Date = Date()) throws -> [String: ProvisioningProfile] {
        let all = all().filter { !$0.isMac && bundleIDs.contains($0.bundleID) }
        let kinds = Self.kinds(for: signing)
        for kind in kinds {
            var chosen: [String: ProvisioningProfile] = [:]
            for id in bundleIDs {
                if let profile = all.filter({ $0.bundleID == id && $0.kind == kind && $0.expires > now }).max(by: { $0.expires < $1.expires }) {
                    chosen[id] = profile
                }
            }
            if chosen.count == Set(bundleIDs).count { return chosen }
        }
        let last = kinds.last ?? .development
        let missing = bundleIDs.first { id in !all.contains { $0.bundleID == id && $0.kind == last && $0.expires > now } } ?? bundleIDs.first ?? ""
        let expired = all.filter { $0.bundleID == missing && kinds.contains($0.kind) }.map(\.expires).max()
        throw PackageCheck.Refusal("No \(Self.list(kinds.map(\.rawValue))) profile for \(missing) in \(folder.path)"
                                   + (expired.map { " (the one there expired on \(Self.day($0)))" } ?? "")
                                   + ": make one for that bundle id in the team's account, listing the devices, and copy it there")
    }

    /// A Mac app's Developer ID profile, if it has one here: only an app
    /// with entitlements Apple restricts needs one.
    func macProfile(for bundleID: String, now: Date = Date()) -> ProvisioningProfile? {
        all().filter { $0.bundleID == bundleID && $0.isMac && $0.kind == .developerID && $0.expires > now }
            .max { $0.expires < $1.expires }
    }

    /// The team the profiles here are of, when they are all one team's.
    func team() -> String? {
        let teams = Set(all().map(\.team))
        return teams.count == 1 ? teams.first : nil
    }

    /// "ad hoc, enterprise or development".
    static func list(_ words: [String]) -> String {
        words.count < 2 ? words.joined() : words.dropLast().joined(separator: ", ") + " or " + (words.last ?? "")
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Which of the server's identities an iPhone app's build is signed with:
/// a beta's (Apple Development, development profiles), or production's (an
/// ad hoc profile's Apple Distribution where there is one, else as a
/// beta's). A Mac app is signed with Developer ID Application either way.
public enum SigningKind: String, Sendable {
    case development
    case production
}
