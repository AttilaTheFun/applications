import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/// What a GitHub Actions job's OIDC token says of it, once verified: the
/// repository and the ref it ran for, the commit, the event that started
/// it and who did, and the run.
public struct CIClaims: Sendable, Equatable {
    /// owner/name.
    public var repository: String
    /// refs/heads/<branch>, refs/tags/<tag>, refs/pull/<n>/merge.
    public var ref: String
    /// "branch" or "tag".
    public var refType: String
    public var sha: String
    /// push, pull_request, release, workflow_dispatch…
    public var eventName: String
    /// The login whose action started the run: who published a release,
    /// pushed a tag or a branch, opened or updated a pull request.
    public var actor: String
    public var runID: String
    /// owner/name/.github/workflows/<file>@<ref>: the workflow that ran.
    public var workflowRef: String
    /// A pull request's branch; empty for any other event.
    public var headRef: String

    public init(repository: String, ref: String, refType: String, sha: String, eventName: String, actor: String, runID: String = "",
                workflowRef: String = "", headRef: String = "") {
        self.repository = repository
        self.ref = ref
        self.refType = refType
        self.sha = sha
        self.eventName = eventName
        self.actor = actor
        self.runID = runID
        self.workflowRef = workflowRef
        self.headRef = headRef
    }

    /// The pull request a run was for (refs/pull/<n>/merge), if any.
    public var pullRequest: Int? {
        let parts = ref.split(separator: "/")
        guard parts.count == 4, parts[0] == "refs", parts[1] == "pull" else { return nil }
        return Int(parts[2])
    }

    /// The branch a run was for: a pull request's own, or the one pushed.
    public var branch: String? {
        if !headRef.isEmpty { return headRef }
        return refType == "branch" && ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : nil
    }

    /// The tag a run was for (refs/tags/<tag>), if any.
    public var tag: String? {
        refType == "tag" && ref.hasPrefix("refs/tags/") ? String(ref.dropFirst("refs/tags/".count)) : nil
    }
}

/// GitHub Actions' OIDC tokens, verified as GitHub signs them: RS256, by a
/// key GitHub lists (its JWKS, fetched when first needed and again when a
/// token names a key not in it), issued by GitHub Actions for this
/// server's audience, and current. What a CI job sends in place of the
/// server's password (`Authorization: Bearer <token>`), asked for with
/// `permissions: id-token: write` and the audience the server names
/// (docs/CI.md).
public actor GitHubOIDC {
    public static let issuer = "https://token.actions.githubusercontent.com"
    public static let defaultAudience = "applications-server"
    /// How far the clocks may disagree.
    static let leeway: TimeInterval = 60
    /// How soon a key GitHub does not list sends for its keys again: a
    /// token naming keys at random is not a way to make the server ask
    /// GitHub over and over.
    static let refetchInterval: TimeInterval = 60

    /// GitHub's keys, as JSON (`{"keys": [JWK…]}`).
    let fetch: @Sendable () async throws -> Data
    /// Each key by its id: its PKCS #1 RSAPublicKey, DER.
    var keys: [String: Data] = [:]
    var fetched: Date?

    public init(fetch: @escaping @Sendable () async throws -> Data = { try await GitHubOIDC.githubKeys() }) {
        self.fetch = fetch
    }

    /// GitHub's JWKS, from https://token.actions.githubusercontent.com/.well-known/jwks.
    public static func githubKeys() async throws -> Data {
        guard let url = URL(string: issuer + "/.well-known/jwks") else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Refusal("GitHub's keys could not be read (status \(status))") }
        return data
    }

    /// Whether a bearer value is a token rather than a password: three
    /// base64url parts, a JSON header first.
    public static func isToken(_ value: String) -> Bool {
        value.hasPrefix("eyJ") && value.split(separator: ".", omittingEmptySubsequences: false).count == 3
    }

    /// The token's claims, once its signature, issuer, audience and times
    /// hold; why not, otherwise.
    public func verify(_ token: String, audience: String, now: Date = Date()) async throws -> CIClaims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Self.base64URL(parts[0]), let payloadData = Self.base64URL(parts[1]),
              let signature = Self.base64URL(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw Refusal("It is not a token (a JWT, three parts)")
        }
        guard header["alg"] as? String == "RS256" else { throw Refusal("It is signed with \(header["alg"] as? String ?? "nothing"), not RS256") }
        guard let kid = header["kid"] as? String, !kid.isEmpty else { throw Refusal("It names no key") }
        let key = try await key(kid, now: now)
        guard try Self.verifyRS256(signature: signature, message: Data((parts[0] + "." + parts[1]).utf8), key: key) else {
            throw Refusal("Its signature does not verify")
        }
        guard claims["iss"] as? String == Self.issuer else {
            throw Refusal("It was issued by \(claims["iss"] as? String ?? "no one"), not GitHub Actions")
        }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(audience) else {
            throw Refusal("It is for \(audiences.joined(separator: ", ")), not this server's audience, \(audience)")
        }
        guard let expires = Self.time(claims["exp"]) else { throw Refusal("It says no expiry") }
        guard now.timeIntervalSince(expires) < Self.leeway else { throw Refusal("It expired at \(expires)") }
        if let notBefore = Self.time(claims["nbf"]), notBefore.timeIntervalSince(now) > Self.leeway {
            throw Refusal("It is not good before \(notBefore)")
        }
        if let issued = Self.time(claims["iat"]), issued.timeIntervalSince(now) > Self.leeway {
            throw Refusal("It was issued in the future, at \(issued)")
        }
        func text(_ name: String) -> String {
            if let value = claims[name] as? String { return value }
            if let value = claims[name] as? NSNumber { return value.stringValue }
            return ""
        }
        let verified = CIClaims(repository: text("repository"), ref: text("ref"), refType: text("ref_type"), sha: text("sha"),
                                eventName: text("event_name"), actor: text("actor"), runID: text("run_id"),
                                workflowRef: text("workflow_ref"), headRef: text("head_ref"))
        for (name, value) in [("repository", verified.repository), ("ref", verified.ref), ("sha", verified.sha),
                              ("event_name", verified.eventName), ("actor", verified.actor)] where value.isEmpty {
            throw Refusal("It says no \(name)")
        }
        return verified
    }

    /// A key GitHub lists, by its id: from the keys fetched, or fetched
    /// again for one not among them (at most once a minute).
    func key(_ kid: String, now: Date) async throws -> Data {
        if let key = keys[kid] { return key }
        if let fetched, now.timeIntervalSince(fetched) < Self.refetchInterval, now >= fetched {
            throw Refusal("It is signed by a key GitHub does not list (\(kid))")
        }
        let data = try await fetch()
        fetched = now
        guard let set = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let listed = set["keys"] as? [[String: Any]] else {
            throw Refusal("GitHub's keys are not a key set")
        }
        var found: [String: Data] = [:]
        for jwk in listed where jwk["kty"] as? String == "RSA" {
            guard let id = jwk["kid"] as? String, let n = (jwk["n"] as? String).flatMap(Self.base64URL),
                  let e = (jwk["e"] as? String).flatMap(Self.base64URL) else { continue }
            found[id] = Self.rsaPublicKey(modulus: n, exponent: e)
        }
        keys = found
        guard let key = found[kid] else { throw Refusal("It is signed by a key GitHub does not list (\(kid))") }
        return key
    }

    /// An RS256 signature (RSASSA-PKCS1-v1_5 over SHA-256) checked with a
    /// PKCS #1 RSAPublicKey: Security's on Apple's systems; swift-crypto's
    /// _RSA would do it on Linux, which the server does not build for yet.
    static func verifyRS256(signature: Data, message: Data, key: Data) throws -> Bool {
        #if canImport(Security)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(key as CFData, attributes as CFDictionary, nil) else {
            throw Refusal("GitHub's key is not an RSA key")
        }
        return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
        #else
        throw Refusal("RS256 is verified with Security, on macOS only for now")
        #endif
    }

    /// A JWK's modulus and exponent as a PKCS #1 RSAPublicKey, DER:
    /// SEQUENCE { INTEGER n, INTEGER e }.
    static func rsaPublicKey(modulus: Data, exponent: Data) -> Data {
        func length(_ count: Int) -> [UInt8] {
            guard count >= 0x80 else { return [UInt8(count)] }
            var bytes: [UInt8] = []
            var rest = count
            while rest > 0 {
                bytes.insert(UInt8(rest & 0xFF), at: 0)
                rest >>= 8
            }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        func integer(_ value: Data) -> [UInt8] {
            var bytes = Array(value.drop { $0 == 0 })
            // Positive: a leading zero when the high bit is set.
            if bytes.first.map({ $0 & 0x80 != 0 }) ?? true { bytes.insert(0, at: 0) }
            return [0x02] + length(bytes.count) + bytes
        }
        let body = integer(modulus) + integer(exponent)
        return Data([0x30] + length(body.count) + body)
    }

    static func base64URL(_ text: String) -> Data? {
        var body = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        return Data(base64Encoded: body)
    }

    /// A NumericDate claim: seconds since 1970.
    static func time(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    public struct Refusal: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }
}
