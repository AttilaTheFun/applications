import ApplicationsProtocol
import Foundation
import PipelineServer

/// Signing on the server, which signs every build CI sends: CI holds no
/// signing key, the server's Mac does (its keychain's identities, the
/// profiles in its data folder, the notary key in its settings).
///
/// - An iPhone app's .ipa: the app and all the code in it (extensions,
///   frameworks, libraries), inside out, each app and extension with the
///   profile for its own bundle id and its own entitlements made the
///   profile's. A beta with the development identity and development
///   profiles; production the same, unless every bundle has an ad hoc
///   profile (installs are over the air to the team's devices, for now).
/// - A Mac app's .zip: Developer ID Application, the hardened runtime and a
///   secure timestamp, on all the code in it, the deepest first (every
///   Mach-O file wherever it is: a bundled tool's too), each with its own
///   entitlements and identifier; notarized and stapled when there is a
///   notary key, betas too, so Gatekeeper takes them.
///
/// Codesign, the keychain and notarytool are `CodeSigning` and
/// `Notarizing`: macOS's here, a test's fakes, and a Linux server's later
/// (rules_applecross signs and notarizes from Linux). Unpacking and
/// packing use ditto and zip.
public struct Signer: Sendable {
    let tools: any CodeSigning
    let notary: any Notarizing
    let profiles: ProfileFolder
    /// The team a Mac app is signed for when it has no profile of its own
    /// (the profiles' team, else the APNs key's); empty when neither says,
    /// and the one Developer ID identity here is taken.
    let team: String

    public init(tools: any CodeSigning, notary: any Notarizing, profiles: URL, team: String) {
        self.tools = tools
        self.notary = notary
        self.profiles = ProfileFolder(folder: profiles, tools: tools)
        self.team = team
    }

    /// Signs an .ipa again in place, with the server's identity of a kind
    /// and the profiles here, every bundle inside out, `schemes` added to
    /// its app's Info.plist first (BuildSchemes: a URL type of their own).
    /// Refused (`PackageCheck.Refusal`), nothing signed, when a bundle in it
    /// has no profile here, or a profile no identity here.
    public func sign(ipa: URL, _ kind: SigningKind, adding schemes: [String] = [], now: Date = Date()) throws {
        let work = try Self.workFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let root = work.appendingPathComponent("package", isDirectory: true)
        try ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", ipa.path, root.path])
        let payload = root.appendingPathComponent("Payload")
        guard let name = ((try? FileManager.default.contentsOfDirectory(atPath: payload.path)) ?? []).first(where: { $0.hasSuffix(".app") }) else {
            throw PackageCheck.Refusal("No app in it")
        }
        let app = payload.appendingPathComponent(name)
        // Every step decided before anything is changed: a profile or an
        // identity missing refuses the build untouched.
        let steps = try iPhoneSteps(app, kind: kind, scratch: work, now: now)
        if !schemes.isEmpty { try Self.addSchemes(schemes, to: app.appendingPathComponent("Info.plist")) }
        for step in steps { try step.run(tools) }
        let signed = work.appendingPathComponent("signed.ipa")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        try ProcessRunner.run("/usr/bin/zip", ["-q", "-r", "-y", "-X", signed.path] + entries, in: root)
        _ = try FileManager.default.replaceItemAt(ipa, withItemAt: signed)
    }

    /// Signs a Mac app's .zip again in place, with Developer ID, and
    /// notarizes and staples it when the notary does: what it came to.
    public func sign(macZip zip: URL, now: Date = Date()) throws -> NotaryResult {
        let work = try Self.workFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let root = work.appendingPathComponent("package", isDirectory: true)
        try ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, root.path])
        guard let name = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).first(where: { $0.hasSuffix(".app") }) else {
            throw PackageCheck.Refusal("No app in it")
        }
        let app = root.appendingPathComponent(name)
        let bundleID = try Self.bundleID(of: app)
        let profile = profiles.macProfile(for: bundleID, now: now)
        let identity = try developerID(team: profile?.team ?? (profiles.team() ?? team), profile: profile)
        var steps: [Step] = []
        // Each piece of code as its signature has it (QEMU's Hypervisor
        // entitlement, a tool's identifier); the app's identifier is its
        // bundle id, which its profile names.
        for code in Self.nestedCode(in: app) {
            steps.append(Step(code: code, request: try macRequest(identity, entitlements: try tools.entitlements(of: code),
                                                                  identifier: try tools.identifier(of: code), scratch: work)))
        }
        var own = try tools.entitlements(of: app)
        if let profile { own = try Self.entitlements(own, bundleID: bundleID, profile: profile) }
        steps.append(Step(code: app, request: try macRequest(identity, entitlements: own, scratch: work),
                          profile: profile.map { ($0.file, app.appendingPathComponent("Contents/embedded.provisionprofile")) }))
        for step in steps { try step.run(tools) }
        // Notarized as the service sees a download: the app zipped and sent,
        // its ticket stapled to it.
        let archive = work.appendingPathComponent("notarize.zip")
        try ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
        let result = try notary.notarize(archive)
        if case .accepted = result { try notary.staple(app) }
        let signed = work.appendingPathComponent("signed.zip")
        try ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, signed.path])
        _ = try FileManager.default.replaceItemAt(zip, withItemAt: signed)
        return result
    }

    /// A disk image of a signed Mac app's .zip, made at `dmg`: the app
    /// beside a link to /Applications, as a Mac app is handed out outside
    /// Applications; signed with Developer ID, then notarized and stapled
    /// when the notary does. What notarizing it came to.
    public func diskImage(ofMacZip zip: URL, volume: String, to dmg: URL, now: Date = Date()) throws -> NotaryResult {
        // One at a time on this Mac: two hdiutils making volumes of one name
        // at once (two releases' promotions) left one hung.
        try Self.diskImages.withLock { try makeDiskImage(ofMacZip: zip, volume: volume, to: dmg, now: now) }
    }

    /// Held while a disk image is made.
    static let diskImages = NSLock()
    /// How long hdiutil may take to make one (a large app's, minutes).
    static let diskImageTimeout: TimeInterval = 15 * 60

    private func makeDiskImage(ofMacZip zip: URL, volume: String, to dmg: URL, now: Date) throws -> NotaryResult {
        let work = try Self.workFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let root = work.appendingPathComponent("package", isDirectory: true)
        try ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, root.path])
        guard let name = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).first(where: { $0.hasSuffix(".app") }) else {
            throw PackageCheck.Refusal("No app in it")
        }
        let app = root.appendingPathComponent(name)
        let bundleID = try Self.bundleID(of: app)
        let profile = profiles.macProfile(for: bundleID, now: now)
        let identity = try developerID(team: profile?.team ?? (profiles.team() ?? team), profile: profile)
        let stage = work.appendingPathComponent("image", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: app, to: stage.appendingPathComponent(name))
        try FileManager.default.createSymbolicLink(atPath: stage.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        try? FileManager.default.removeItem(at: dmg)
        try ProcessRunner.run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", volume, "-srcfolder", stage.path, "-format", "UDZO",
                                                   "-fs", "APFS", dmg.path], timeout: Self.diskImageTimeout)
        try tools.sign(dmg, SigningRequest(identity: identity, timestamp: true))
        let result = try notary.notarize(dmg)
        if case .accepted = result { try notary.staple(dmg) }
        return result
    }

    // MARK: iPhone

    /// What signing an iPhone app takes, inside out: each piece of code in
    /// it, then the app; an app's or extension's profile (one kind for all
    /// of them) and entitlements; frameworks, libraries and any other
    /// Mach-O file with the app's identity and none.
    func iPhoneSteps(_ app: URL, kind: SigningKind, scratch: URL, now: Date) throws -> [Step] {
        let appID = try Self.bundleID(of: app)
        let nested = Self.nestedCode(in: app)
        var bundleIDs = [appID]
        for code in nested where Self.provisioned.contains(code.pathExtension) {
            let id = try Self.bundleID(of: code)
            // An extension's (or a watch app's) id begins with its app's, as
            // Apple has it: the server signs no other app's id inside this one.
            guard id.hasPrefix(appID + ".") else {
                throw PackageCheck.Refusal("\(code.lastPathComponent) in \(appID) is \(id), which is not one of \(appID)'s own "
                                           + "(an extension's bundle id begins with its app's)")
            }
            bundleIDs.append(id)
        }
        let chosen = try profiles.iPhoneProfiles(for: bundleIDs, signing: kind, now: now)
        let identities = try tools.identities()
        guard let appProfile = chosen[appID] else { throw PackageCheck.Refusal("No profile for \(appID)") }
        let appIdentity = try identity(for: appProfile, bundleID: appID, in: identities)
        var steps: [Step] = []
        for code in nested + [app] {
            guard code == app || Self.provisioned.contains(code.pathExtension) else {
                steps.append(Step(code: code, request: SigningRequest(identity: appIdentity)))
                continue
            }
            let id = code == app ? appID : try Self.bundleID(of: code)
            guard let profile = chosen[id] else { throw PackageCheck.Refusal("No profile for \(id)") }
            let entitlements = try Self.entitlements(try tools.entitlements(of: code), bundleID: id, profile: profile)
            steps.append(Step(code: code,
                              request: SigningRequest(identity: try identity(for: profile, bundleID: id, in: identities),
                                                      entitlements: try Self.write(entitlements, in: scratch)),
                              profile: (profile.file, code.appendingPathComponent("embedded.mobileprovision"))))
        }
        return steps
    }

    /// The identity here whose certificate a profile names.
    func identity(for profile: ProvisioningProfile, bundleID: String, in identities: [SigningIdentity]) throws -> String {
        guard let identity = identities.first(where: { profile.certificates.contains($0.sha1) }) else {
            let certificate = profile.kind == .development ? "Apple Development" : "Apple Distribution"
            throw PackageCheck.Refusal("No identity in this Mac's keychain for the certificates \(bundleID)'s \(profile.kind.rawValue) profile "
                                       + "(\(profile.name)) names: install its \(certificate) certificate and private key from the team's account")
        }
        return identity.sha1
    }

    /// A bundle's entitlements made its profile's: its own as it was built
    /// (or, for one that came with none, the profile's, wildcards resolved
    /// or left out), with the profile's application identifier and team,
    /// keychain groups of the team, and the profile's push environment and
    /// debugging. On an iPhone, refused when it asks for one the profile
    /// does not allow, which iOS would refuse to install; a Mac app's
    /// unrestricted ones (its sandbox) are no profile's.
    static func entitlements(_ own: [String: Any], bundleID: String, profile: ProvisioningProfile) throws -> [String: Any] {
        let allowed = profile.entitlements
        let mac = profile.isMac
        let identifierKey = mac ? "com.apple.application-identifier" : "application-identifier"
        let pushKey = mac ? "com.apple.developer.aps-environment" : "aps-environment"
        let debugKey = mac ? "com.apple.security.get-task-allow" : "get-task-allow"
        var result = own.isEmpty ? concrete(allowed, prefix: profile.prefix, bundleID: bundleID) : own
        // The prefix it was built with, if any, which its keychain groups
        // begin with too.
        let built = (own[identifierKey] as? String)?.split(separator: ".", maxSplits: 1).first.map { String($0) + "." }
        result[identifierKey] = profile.prefix + "." + bundleID
        if allowed["com.apple.developer.team-identifier"] != nil { result["com.apple.developer.team-identifier"] = profile.team }
        if let groups = result["keychain-access-groups"] as? [String] {
            result["keychain-access-groups"] = groups.map { group in
                for old in ["$(AppIdentifierPrefix)"] + (built.map { [$0] } ?? []) where group.hasPrefix(old) {
                    return profile.prefix + "." + group.dropFirst(old.count)
                }
                return group
            }
        }
        if result[pushKey] != nil, let environment = allowed[pushKey] { result[pushKey] = environment }
        result[debugKey] = allowed[debugKey]
        if !mac {
            let refused = result.keys.filter { allowed[$0] == nil }.sorted()
            guard refused.isEmpty else {
                throw PackageCheck.Refusal("\(bundleID)'s profile (\(profile.name)) does not allow \(refused.joined(separator: ", ")): give "
                                           + "its App ID those capabilities, make the profile again and copy it to the server's profiles")
            }
        }
        return result
    }

    /// A profile's entitlements for a bundle that came with none: its
    /// team's wildcard keychain group made the bundle's own, other
    /// wildcards left out.
    static func concrete(_ allowed: [String: Any], prefix: String, bundleID: String) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in allowed {
            switch value {
            case let text as String:
                if !text.contains("*") { result[key] = text }
            case let list as [String]:
                let kept = list.compactMap { item in item == prefix + ".*" ? prefix + "." + bundleID : item.contains("*") ? nil : item }
                if !kept.isEmpty { result[key] = kept }
            default:
                result[key] = value
            }
        }
        return result
    }

    // MARK: Mac

    /// The Developer ID Application identity a Mac app is signed with: the
    /// one its profile names, if it has one; else the team's.
    func developerID(team: String, profile: ProvisioningProfile?) throws -> String {
        let theirs = try tools.identities().filter { $0.kind == .developerID }
        if let profile, let named = theirs.first(where: { profile.certificates.contains($0.sha1) }) { return named.sha1 }
        let ofTeam = team.isEmpty ? theirs : theirs.filter { $0.team == team }
        if let identity = ofTeam.first, !team.isEmpty || ofTeam.count == 1 { return identity.sha1 }
        if theirs.isEmpty {
            throw PackageCheck.Refusal("No Developer ID Application identity in this Mac's keychain: install the team's certificate and "
                                       + "private key, from its account")
        }
        throw PackageCheck.Refusal(team.isEmpty
            ? "More than one team's Developer ID Application identity here, and nothing says which: put the app's profile, or the "
                + "team's iPhone profiles, in the server's profiles"
            : "No Developer ID Application identity of the profiles' team in this Mac's keychain")
    }

    /// How a Mac app's code is signed: Developer ID, the hardened runtime, a
    /// secure timestamp, its own entitlements but debugging (which the
    /// notary service refuses), and its own identifier if it is given one.
    func macRequest(_ identity: String, entitlements: [String: Any], identifier: String? = nil, scratch: URL) throws -> SigningRequest {
        var entitlements = entitlements
        entitlements["com.apple.security.get-task-allow"] = nil
        return SigningRequest(identity: identity, identifier: identifier,
                              entitlements: entitlements.isEmpty ? nil : try Self.write(entitlements, in: scratch),
                              hardenedRuntime: true, timestamp: true)
    }

    // MARK: Bundles

    /// One piece of code to sign, and the profile copied into it first.
    struct Step {
        var code: URL
        var request: SigningRequest
        var profile: (from: URL, to: URL)?

        func run(_ tools: any CodeSigning) throws {
            if let profile {
                try? FileManager.default.removeItem(at: profile.to)
                try FileManager.default.copyItem(at: profile.from, to: profile.to)
            }
            try tools.sign(code, request)
        }
    }

    /// The kinds of bundle that are code of their own, signed apart.
    static let codeBundles: Set<String> = ["app", "appex", "framework", "xpc", "bundle", "plugin", "systemextension"]
    /// Those that carry a profile and entitlements of their own on an
    /// iPhone: apps (a watch app, an App Clip) and extensions.
    static let provisioned: Set<String> = ["app", "appex"]

    /// The code inside a bundle, the deepest first, so each is signed after
    /// what is in it: bundles of code, and every Mach-O file but a bundle's
    /// own executable (signed with its bundle), wherever it is: libraries,
    /// a Mac bundle's executables beside its own, a bundled tool's in its
    /// own folders (Contents/Helpers/qemu/bin). Files of any other kind are
    /// left to their bundle's seal, and symbolic links (a Mac framework's
    /// Versions/Current) are not followed.
    static func nestedCode(in bundle: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: keys) else { return [] }
        var found: [URL] = []
        for case let item as URL in walker {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                if codeBundles.contains(item.pathExtension), hasCode(item) { found.append(item) }
            } else if values.isRegularFile == true, isMachO(item), !isBundleExecutable(item) {
                found.append(item)
            }
        }
        return found.sorted { ($0.pathComponents.count, $1.path) > ($1.pathComponents.count, $0.path) }
    }

    /// Whether a bundle has code to sign: a resource bundle has none.
    static func hasCode(_ bundle: URL) -> Bool {
        guard ["bundle", "plugin"].contains(bundle.pathExtension) else { return true }
        guard let executable = info(of: bundle)?["CFBundleExecutable"] as? String else { return false }
        return ["Contents/MacOS/" + executable, executable].contains { FileManager.default.fileExists(atPath: bundle.appendingPathComponent($0).path) }
    }

    /// Whether a file is Mach-O code, by its first bytes, whatever its name
    /// or permissions: thin (32- or 64-bit) or universal (fat, of 32- or
    /// 64-bit offsets), in either byte order. Java's class files begin as a
    /// universal binary does; what follows tells them apart (a universal
    /// binary's count of architectures, a class file's version, 45 or
    /// more).
    static func isMachO(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count == 8 else { return false }
        // Both words read big-endian; a little-endian header's swapped back.
        let bytes = [UInt8](head)
        let magic = bytes[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let next = bytes[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        switch magic {
        case 0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE:
            return true
        case 0xCAFEBABE, 0xCAFEBABF:
            return (1..<45).contains(next)
        case 0xBEBAFECA, 0xBFBAFECA:
            return (1..<45).contains(next.byteSwapped)
        default:
            return false
        }
    }

    /// Whether a file is a bundle's own executable, which is signed with
    /// its bundle rather than apart: in a Mac bundle's Contents/MacOS, at
    /// an iPhone bundle's top, or in a Mac framework's Versions/<version>,
    /// named by that bundle's Info.plist.
    static func isBundleExecutable(_ file: URL) -> Bool {
        let folder = file.deletingLastPathComponent(), above = folder.deletingLastPathComponent()
        let bundle: URL
        if folder.lastPathComponent == "MacOS", above.lastPathComponent == "Contents" {
            bundle = above.deletingLastPathComponent()
        } else if codeBundles.contains(folder.pathExtension)
                    || above.lastPathComponent == "Versions" && above.deletingLastPathComponent().pathExtension == "framework" {
            bundle = folder
        } else {
            return false
        }
        return info(of: bundle)?["CFBundleExecutable"] as? String == file.lastPathComponent
    }

    /// A bundle's Info.plist: a Mac bundle's in Contents, an iPhone one's
    /// at its top, a Mac framework's in its Resources.
    static func info(of bundle: URL) -> [String: Any]? {
        for path in ["Contents/Info.plist", "Info.plist", "Resources/Info.plist"] {
            guard let data = try? Data(contentsOf: bundle.appendingPathComponent(path)) else { continue }
            return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        }
        return nil
    }

    static func bundleID(of bundle: URL) throws -> String {
        guard let id = info(of: bundle)?["CFBundleIdentifier"] as? String, !id.isEmpty else {
            throw PackageCheck.Refusal("\(bundle.lastPathComponent) names no bundle id")
        }
        return id
    }

    /// Puts the schemes in Info.plist as a URL type of their own
    /// (BuildSchemes.urlName), as CI stamps them.
    static func addSchemes(_ schemes: [String], to plist: URL) throws {
        let data = try Data(contentsOf: plist)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var info = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any] else {
            throw PackageCheck.Refusal("Its Info.plist is not a dictionary")
        }
        var types = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        types.append(["CFBundleURLName": BuildSchemes.urlName, "CFBundleURLSchemes": schemes])
        info["CFBundleURLTypes"] = types
        try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0).write(to: plist)
    }

    /// Entitlements as the property list codesign is given.
    static func write(_ entitlements: [String: Any], in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent("entitlements-" + UUID().uuidString + ".plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: file)
        return file
    }

    static func workFolder() throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("sign-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }
}
