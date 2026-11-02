import CryptoKit
import Foundation
import PipelineServer
#if canImport(Security)
import Security
#endif

/// What signing asks of the computer the server runs on: its signing
/// identities, a provisioning profile's contents, the entitlements and
/// identifier code is signed with, and codesign itself. `SystemCodeSigning`
/// is macOS's (the keychain, security and codesign); a test's is a fake; a
/// Linux server's would be rules_applecross's codesign, which signs Apple's
/// code off a Mac.
public protocol CodeSigning: Sendable {
    /// The identities codesign can sign with here, each of a kind and a
    /// team.
    func identities() throws -> [SigningIdentity]
    /// A provisioning profile's property list, out of its signed envelope.
    func profile(_ file: URL) throws -> Data
    /// The entitlements `code` is signed with: none when it has none, or is
    /// not signed at all.
    func entitlements(of code: URL) throws -> [String: Any]
    /// The identifier `code` is signed with ("qemu-img", a bundle's id):
    /// nil when it is not signed.
    func identifier(of code: URL) throws -> String?
    /// Signs `code` (a bundle, or a single executable or library), whatever
    /// is inside it signed already.
    func sign(_ code: URL, _ request: SigningRequest) throws
}

/// One of the computer's signing identities, found by its kind and team:
/// never named in the repository, nor printed.
public struct SigningIdentity: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// "Apple Development": betas, with development profiles.
        case development = "Apple Development"
        /// "Apple Distribution": production, with an ad hoc profile.
        case distribution = "Apple Distribution"
        /// "Developer ID Application": Mac apps, notarized.
        case developerID = "Developer ID Application"
    }

    /// The SHA-1 of its certificate, in uppercase hex: what codesign is
    /// given, and what a provisioning profile's certificates are matched by.
    public var sha1: String
    public var kind: Kind
    /// Its certificate's organizational unit: the team.
    public var team: String

    public init(sha1: String, kind: Kind, team: String) {
        self.sha1 = sha1
        self.kind = kind
        self.team = team
    }

    /// The kind a certificate's common name says: "Apple Development: …"
    /// (or "iPhone Developer: …", its name before 2019), and so on; nil for
    /// any other.
    public static func kind(ofCommonName name: String) -> Kind? {
        if name.hasPrefix("Apple Development:") || name.hasPrefix("iPhone Developer:") { return .development }
        if name.hasPrefix("Apple Distribution:") || name.hasPrefix("iPhone Distribution:") { return .distribution }
        if name.hasPrefix("Developer ID Application:") { return .developerID }
        return nil
    }

    /// A certificate's SHA-1, in uppercase hex.
    public static func sha1(of certificate: Data) -> String {
        Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined()
    }
}

/// How one piece of code is signed.
public struct SigningRequest: Sendable, Equatable {
    /// An identity's SHA-1, or "-" (ad hoc).
    public var identity: String
    /// The identifier to sign with (`--identifier`): what its signature
    /// said before, for a Mac app's nested code; nil for codesign's own (a
    /// bundle's id, else the file's name).
    public var identifier: String?
    /// A property list of the entitlements to sign with; none for code that
    /// has none (frameworks, libraries).
    public var entitlements: URL?
    /// The hardened runtime (`--options runtime`), which notarization asks
    /// of a Mac app's code.
    public var hardenedRuntime: Bool
    /// A secure timestamp (`--timestamp`), which notarization asks for;
    /// false for none (`--timestamp=none`, an iPhone app's); nil for
    /// codesign's own default.
    public var timestamp: Bool?

    public init(identity: String, identifier: String? = nil, entitlements: URL? = nil, hardenedRuntime: Bool = false,
                timestamp: Bool? = false) {
        self.identity = identity
        self.identifier = identifier
        self.entitlements = entitlements
        self.hardenedRuntime = hardenedRuntime
        self.timestamp = timestamp
    }
}

/// What notarizing a Mac app came to.
public enum NotaryResult: Sendable, Equatable {
    /// Apple's notary service accepted it, as this submission.
    case accepted(submission: String)
    /// Not notarized, and why (no notary key here): the app is signed, and
    /// published as it is.
    case skipped(String)
}

/// Notarizing a Mac app: `NotaryTool` (notarytool with the App Store Connect
/// API key the server keeps), `SkippedNotary` without one, a test's fake.
public protocol Notarizing: Sendable {
    /// Sends a zip of the app to Apple's notary service and waits for its
    /// answer: accepted, or skipped; throws (a `PackageCheck.Refusal`, with
    /// what the service found) when it is not accepted.
    func notarize(_ archive: URL) throws -> NotaryResult
    /// Staples the service's ticket to the app, so Gatekeeper takes it
    /// offline too.
    func staple(_ app: URL) throws
}

/// No notary key here (`applications-server notary`): Mac apps are
/// signed, not notarized.
public struct SkippedNotary: Notarizing {
    let reason: String

    public init(reason: String) { self.reason = reason }

    public func notarize(_ archive: URL) throws -> NotaryResult { .skipped(reason) }
    public func staple(_ app: URL) throws {}
}

/// macOS's signing: the identities in this user's keychain, profiles
/// opened with `security cms`, and /usr/bin/codesign. The keychain's
/// private keys must let codesign use them without asking (their access
/// control, in Keychain Access), as the server runs with no one at the
/// screen.
public struct SystemCodeSigning: CodeSigning {
    public init() {}

    public func identities() throws -> [SigningIdentity] {
        #if canImport(Security) && os(macOS)
        // The identities codesign takes as valid now (not expired, nor
        // revoked), by their SHA-1s.
        let listing = String(decoding: try ProcessRunner.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]), as: UTF8.self)
        let valid = Set(listing.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ")
            guard parts.count > 1, parts[1].count == 40 else { return nil }
            return String(parts[1])
        })
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnRef as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let found = result as? [SecIdentity] else { return [] }
        var identities: [SigningIdentity] = []
        for identity in found {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                  let name = SecCertificateCopySubjectSummary(certificate) as String?, let kind = SigningIdentity.kind(ofCommonName: name)
            else { continue }
            let sha1 = SigningIdentity.sha1(of: SecCertificateCopyData(certificate) as Data)
            guard valid.contains(sha1), !identities.contains(where: { $0.sha1 == sha1 }) else { continue }
            identities.append(SigningIdentity(sha1: sha1, kind: kind, team: Self.organizationalUnit(of: certificate) ?? ""))
        }
        return identities
        #else
        throw PackageCheck.Refusal("No keychain here to sign with: a Linux server signs with rules_applecross's codesign, which is not wired in yet")
        #endif
    }

    #if canImport(Security) && os(macOS)
    /// The certificate's subject's organizational unit: an Apple
    /// certificate's team.
    static func organizationalUnit(of certificate: SecCertificate) -> String? {
        let keys = [kSecOIDX509V1SubjectName] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
              let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
              let entries = subject[kSecPropertyKeyValue as String] as? [[String: Any]] else { return nil }
        return entries.first { ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDOrganizationalUnitName as String) }?[
            kSecPropertyKeyValue as String] as? String
    }
    #endif

    public func profile(_ file: URL) throws -> Data {
        try ProcessRunner.run("/usr/bin/security", ["cms", "-D", "-i", file.path])
    }

    public func entitlements(of code: URL) throws -> [String: Any] {
        // Code with no signature has none: codesign says so and fails.
        guard let signed = try? ProcessRunner.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", code.path]),
              !signed.isEmpty else { return [:] }
        return (try PropertyListSerialization.propertyList(from: signed, format: nil) as? [String: Any]) ?? [:]
    }

    public func identifier(of code: URL) throws -> String? {
        #if canImport(Security) && os(macOS)
        // Its signature's, as `codesign -d` shows it (Identifier=): none
        // for code with no signature.
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(code as CFURL, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(), &information) == errSecSuccess else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
        #else
        return nil
        #endif
    }

    public func sign(_ code: URL, _ request: SigningRequest) throws {
        var arguments = ["--force", "--sign", request.identity]
        if let identifier = request.identifier { arguments += ["--identifier", identifier] }
        if let entitlements = request.entitlements { arguments += ["--entitlements", entitlements.path] }
        if request.hardenedRuntime { arguments += ["--options", "runtime"] }
        if let timestamp = request.timestamp { arguments.append(timestamp ? "--timestamp" : "--timestamp=none") }
        do {
            try ProcessRunner.run("/usr/bin/codesign", arguments + [code.path])
        } catch let failure as ProcessRunner.Failure {
            // What codesign said, without the identity it was given.
            throw PackageCheck.Refusal("codesign could not sign \(code.lastPathComponent): "
                                       + failure.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Notarizing with notarytool and an App Store Connect API key (its .p8
/// kept in the data folder as notary.p8, its id and issuer in config.json:
/// `applications-server notary`), then stapling with stapler. Neither the
/// key nor its ids are ever printed: what fails says what notarytool said,
/// not what it was run with.
public struct NotaryTool: Notarizing {
    let key: URL
    let keyID: String
    let issuer: String

    public init(key: URL, keyID: String, issuer: String) {
        self.key = key
        self.keyID = keyID
        self.issuer = issuer
    }

    private var credentials: [String] { ["--key", key.path, "--key-id", keyID, "--issuer", issuer] }

    public func notarize(_ archive: URL) throws -> NotaryResult {
        // Waited for here: minutes, as a rule; the publish waits with it.
        let submitted = try Self.run(["notarytool", "submit", archive.path] + credentials
                                     + ["--wait", "--timeout", "45m", "--output-format", "json"])
        guard let answer = try? JSONSerialization.jsonObject(with: submitted.output) as? [String: Any],
              let id = answer["id"] as? String, let status = answer["status"] as? String else {
            throw PackageCheck.Refusal("notarytool did not say how the submission went: " + submitted.errors)
        }
        guard status == "Accepted" else {
            // What the service found, from the submission's log.
            let log = try? Self.run(["notarytool", "log", id] + credentials)
            let issues = (log.flatMap { try? JSONSerialization.jsonObject(with: $0.output) as? [String: Any] }?["issues"] as? [[String: Any]] ?? [])
                .compactMap { issue -> String? in
                    guard let message = issue["message"] as? String else { return nil }
                    return ((issue["path"] as? String).map { $0 + ": " } ?? "") + message
                }
            throw PackageCheck.Refusal("Apple's notary service answered \(status) for submission \(id)"
                                       + (issues.isEmpty ? "" : ": " + issues.prefix(5).joined(separator: "; ")))
        }
        return .accepted(submission: id)
    }

    public func staple(_ app: URL) throws {
        let stapled = try Self.run(["stapler", "staple", "-q", app.path])
        guard stapled.status == 0 else { throw PackageCheck.Refusal("stapler could not staple the notarization: " + stapled.errors) }
    }

    /// xcrun run to its end, its output and errors kept in files (notarytool
    /// says a lot while it waits) and its status returned rather than
    /// thrown, so its JSON is read whatever it exited with.
    private static func run(_ arguments: [String]) throws -> (status: Int32, output: Data, errors: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notary-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output"), errors = folder.appendingPathComponent("errors")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: errors)
        try process.run()
        process.waitUntilExit()
        let said = String(decoding: (try? Data(contentsOf: errors)) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, (try? Data(contentsOf: output)) ?? Data(), said)
    }
}
