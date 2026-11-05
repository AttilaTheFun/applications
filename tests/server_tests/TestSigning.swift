import ApplicationsProtocol
import Foundation
import Security
import Synchronization
@testable import ApplicationsServer

/// What the fakes saw, in order: each signing, notarizing and stapling.
final class SigningEvents: Sendable {
    private let list = Mutex<[String]>([])

    func add(_ event: String) { list.withLock { $0.append(event) } }
    var all: [String] { list.withLock { $0 } }
}

/// codesign and the keychain, faked: the identities are the test team's
/// (TestProfile), a profile is read as the plain property list a test
/// writes, a piece of code's entitlements and identifier are what the test
/// gives for its name, and each signing is recorded, with the profile in
/// the bundle and the entitlements and identifier it was given. `adHoc`:
/// each is signed ad hoc as well, by the real codesign with no identity, so
/// the server's check after signing passes.
final class FakeCodeSigning: CodeSigning {
    struct Signed: Equatable {
        /// The code's path from its app: "Visor.app/PlugIns/Widgets.appex".
        var path: String
        var identity: String
        var hardenedRuntime: Bool
        var timestamp: Bool?
        /// The application identifier its entitlements were given, if any.
        var applicationIdentifier: String?
        /// Whether its entitlements let it be debugged (a development
        /// profile's), if they say.
        var debuggable: Bool?
        /// The name of the profile in it as it was signed, if any.
        var profile: String?
        /// The identifier it was given (`--identifier`), if any.
        var identifier: String?
    }

    let identityList: [SigningIdentity]
    /// Each piece of code's own entitlements, by its file name, as property
    /// lists.
    let ownEntitlements: [String: Data]
    /// Each piece of code's own identifier, by its file name.
    let ownIdentifiers: [String: String]
    let adHoc: Bool
    let events: SigningEvents
    private let signings = Mutex<[Signed]>([])
    /// The entitlements each signing was given, by its path, as property
    /// lists.
    private let given = Mutex<[String: Data]>([:])

    init(identities: [SigningIdentity] = TestProfile.identities, ownEntitlements: [String: [String: Any]] = [:],
         ownIdentifiers: [String: String] = [:], adHoc: Bool = false, events: SigningEvents = SigningEvents()) {
        identityList = identities
        self.ownEntitlements = ownEntitlements.compactMapValues {
            try? PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0)
        }
        self.ownIdentifiers = ownIdentifiers
        self.adHoc = adHoc
        self.events = events
    }

    var signed: [Signed] { signings.withLock { $0 } }

    /// The entitlements the code at `path` (from its app, as `Signed`'s)
    /// was signed with: nil when it was given none.
    func entitlementsGiven(_ path: String) -> NSDictionary? {
        guard let data = given.withLock({ $0[path] }) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
    }

    func identities() throws -> [SigningIdentity] { identityList }

    func profile(_ file: URL) throws -> Data { try Data(contentsOf: file) }

    func entitlements(of code: URL) throws -> [String: Any] {
        guard let data = ownEntitlements[code.lastPathComponent] else { return [:] }
        return (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]
    }

    func identifier(of code: URL) throws -> String? { ownIdentifiers[code.lastPathComponent] }

    func sign(_ code: URL, _ request: SigningRequest) throws {
        let entitlementsData = request.entitlements.flatMap { try? Data(contentsOf: $0) }
        let entitlements = entitlementsData
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let embedded = ["embedded.mobileprovision", "Contents/embedded.provisionprofile"].map { code.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let profile = embedded.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?["Name"] as? String
        let components = code.pathComponents
        let path = components[(components.firstIndex { $0.hasSuffix(".app") } ?? 0)...].joined(separator: "/")
        let applicationIdentifier = (entitlements?["application-identifier"] ?? entitlements?["com.apple.application-identifier"]) as? String
        let debuggable = (entitlements?["get-task-allow"] ?? entitlements?["com.apple.security.get-task-allow"]) as? Bool
        signings.withLock {
            $0.append(Signed(path: path, identity: request.identity, hardenedRuntime: request.hardenedRuntime, timestamp: request.timestamp,
                             applicationIdentifier: applicationIdentifier, debuggable: debuggable, profile: profile,
                             identifier: request.identifier))
        }
        if let entitlementsData { given.withLock { $0[path] = entitlementsData } }
        events.add("sign " + path)
        if adHoc {
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-"] + (request.entitlements.map { ["--entitlements", $0.path] } ?? []) + [code.path]
            sign.standardError = FileHandle.nullDevice
            try sign.run()
            sign.waitUntilExit()
        }
    }
}

/// notarytool faked: it accepts, or says it notarized nothing.
final class FakeNotary: Notarizing {
    let accepts: Bool
    let events: SigningEvents

    init(accepts: Bool, events: SigningEvents) {
        self.accepts = accepts
        self.events = events
    }

    func notarize(_ archive: URL) throws -> NotaryResult {
        events.add("notarize")
        return accepts ? .accepted(submission: "test-submission") : .skipped("the fake notarizes nothing")
    }

    func staple(_ app: URL) throws { events.add("staple " + app.lastPathComponent) }
}

/// Provisioning profiles as a test writes them: the property list
/// `security cms -D` gives of one, which the fake reads as it is.
enum TestProfile {
    static let team = "TESTTEAM01"
    static let developmentCertificate = Data("development certificate".utf8)
    static let distributionCertificate = Data("distribution certificate".utf8)
    static let developerIDCertificate = Data("developer id certificate".utf8)

    static var identities: [SigningIdentity] {
        [SigningIdentity(sha1: SigningIdentity.sha1(of: developmentCertificate), kind: .development, team: team),
         SigningIdentity(sha1: SigningIdentity.sha1(of: distributionCertificate), kind: .distribution, team: team),
         SigningIdentity(sha1: SigningIdentity.sha1(of: developerIDCertificate), kind: .developerID, team: team)]
    }

    static func sha1(_ kind: SigningIdentity.Kind) -> String {
        identities.first { $0.kind == kind }?.sha1 ?? ""
    }

    /// A profile's name: its kind and bundle id ("development com.example.Visor").
    static func name(_ kind: String, _ bundleID: String) -> String { kind + " " + bundleID }

    /// A profile for a bundle id, of a kind ("development", "ad hoc",
    /// "App Store", "Developer ID"), written into `folder`.
    @discardableResult
    static func write(in folder: URL, bundleID: String, kind: String = "development", expires: Date = Date().addingTimeInterval(86_400 * 365),
                      push: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mac = kind == "Developer ID"
        var entitlements: [String: Any] = [mac ? "com.apple.application-identifier" : "application-identifier": "\(team).\(bundleID)",
                                           "com.apple.developer.team-identifier": team,
                                           "keychain-access-groups": ["\(team).*", "com.apple.token"]]
        if !mac { entitlements["get-task-allow"] = kind == "development" }
        if push { entitlements[mac ? "com.apple.developer.aps-environment" : "aps-environment"] = kind == "development" ? "development" : "production" }
        let certificate = kind == "development" ? developmentCertificate : mac ? developerIDCertificate : distributionCertificate
        var info: [String: Any] = ["Name": name(kind, bundleID), "ApplicationIdentifierPrefix": [team], "TeamIdentifier": [team],
                                   "Platform": [mac ? "OSX" : "iOS"], "ExpirationDate": expires, "DeveloperCertificates": [certificate],
                                   "Entitlements": entitlements]
        if ["development", "ad hoc"].contains(kind) { info["ProvisionedDevices"] = ["00000000-TESTDEVICE"] }
        if mac { info["ProvisionsAllDevices"] = true }
        let file = folder.appendingPathComponent("\(bundleID).\(kind.replacingOccurrences(of: " ", with: ""))."
                                                 + (mac ? "provisionprofile" : "mobileprovision"))
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: file)
        return file
    }
}

/// GitHub Actions' tokens, made with a test's own RSA key and key set.
enum TestToken {
    struct Key {
        let privateKey: SecKey
        let kid: String
        let jwk: [String: String]
    }

    /// A 2048-bit RSA key, in memory only, and its JWK.
    static func key(kid: String) throws -> Key {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error), let publicKey = SecKeyCopyPublicKey(privateKey),
              let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error?.takeRetainedValue() ?? CocoaError(.featureUnsupported)
        }
        let integers = integers(der)
        guard integers.count == 2 else { throw CocoaError(.coderInvalidValue) }
        return Key(privateKey: privateKey, kid: kid,
                   jwk: ["kty": "RSA", "alg": "RS256", "use": "sig", "kid": kid, "n": base64URL(integers[0]), "e": base64URL(integers[1])])
    }

    /// GitHub's JWKS, as these keys.
    static func jwks(_ keys: [Key]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["keys": keys.map(\.jwk)])) ?? Data()
    }

    /// The claims of a run: main's push by the owner, unless told otherwise.
    static func claims(repository: String = "AttilaTheFun/visor", repositoryID: String = "1000", ref: String = "refs/heads/main",
                       refType: String = "branch", event: String = "push", actor: String = "AttilaTheFun", headRef: String = "",
                       sha: String = "0123456789abcdef0123456789abcdef01234567", audience: String = "applications-server",
                       issuer: String = "https://token.actions.githubusercontent.com", now: Date = Date(),
                       expiresIn: TimeInterval = 300) -> [String: Any] {
        let issued = Int(now.timeIntervalSince1970) - 5
        return ["iss": issuer, "aud": audience, "iat": issued, "nbf": issued, "exp": issued + Int(expiresIn),
                "sub": "repo:\(repository):ref:\(ref)", "repository": repository, "repository_id": repositoryID,
                "repository_owner": "AttilaTheFun", "ref": ref,
                "ref_type": refType, "sha": sha, "event_name": event, "actor": actor, "head_ref": headRef, "base_ref": "",
                "run_id": "4242", "workflow_ref": "\(repository)/.github/workflows/ci.yml@\(ref)"]
    }

    /// A token of `claims` signed with `key` (named as `kid`, if given).
    static func token(_ claims: [String: Any], key: Key, kid: String? = nil, algorithm: String = "RS256") throws -> String {
        let header = base64URL(try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": kid ?? key.kid, "typ": "JWT"]))
        let input = header + "." + base64URL(try JSONSerialization.data(withJSONObject: claims))
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key.privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData,
                                                    &error) as Data? else {
            throw error?.takeRetainedValue() ?? CocoaError(.featureUnsupported)
        }
        return input + "." + base64URL(signature)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A PKCS #1 RSAPublicKey's two integers, the modulus and the exponent,
    /// without their leading zeros.
    static func integers(_ der: Data) -> [Data] {
        let bytes = [UInt8](der)
        var index = 0
        func length() -> Int {
            guard index < bytes.count else { return 0 }
            let first = Int(bytes[index])
            index += 1
            guard first & 0x80 != 0 else { return first }
            var value = 0
            for _ in 0..<(first & 0x7F) where index < bytes.count {
                value = value << 8 | Int(bytes[index])
                index += 1
            }
            return value
        }
        guard bytes.first == 0x30 else { return [] }
        index = 1
        _ = length()
        var found: [Data] = []
        while index < bytes.count, bytes[index] == 0x02 {
            index += 1
            let count = length()
            guard index + count <= bytes.count else { break }
            var value = Array(bytes[index..<index + count])
            index += count
            while value.count > 1, value.first == 0 { value.removeFirst() }
            found.append(Data(value))
        }
        return found
    }
}

/// GitHub's keys as a test serves them: changed when it likes, and counted.
actor KeySource {
    var keys: Data
    private(set) var fetches = 0

    init(_ keys: Data) { self.keys = keys }

    func fetch() -> Data {
        fetches += 1
        return keys
    }

    func change(to keys: Data) { self.keys = keys }
}

/// A release's iPhone build kept as its CI has it published, now that
/// nothing else makes one production: readied with the server's signer (a
/// fake codesign that signs ad hoc, so the check after signing passes, and
/// a development profile for its bundle id, which production signs with
/// when it has no ad hoc one), its scheme given, then kept as production.
enum TestRelease {
    @discardableResult
    static func keep(_ package: URL, in store: BuildStore, commit: String? = nil, now: Date = Date()) throws -> Build {
        let profiles = store.folder.deletingLastPathComponent().appendingPathComponent("release-profiles")
        let (file, metadata) = try store.unpack(package)
        try TestProfile.write(in: profiles, bundleID: metadata.bundleID)
        let signer = Signer(tools: FakeCodeSigning(adHoc: true), notary: SkippedNotary(reason: "an iPhone app"), profiles: profiles,
                            team: TestProfile.team)
        let scheme = try store.ready(file, metadata: metadata, channel: .production, commit: commit, signer: signer)
        return try store.keep(file, metadata: metadata, buildScheme: scheme, notes: "", app: nil, origin: commit.map { BuildOrigin(commit: $0) },
                              channel: .production, now: now, keeps: { $0.channel == .production })
    }
}
