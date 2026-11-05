import Foundation
import XCTest
@testable import ApplicationsServer

/// CI's tokens (GitHubOIDC): RS256 by a key GitHub lists, issued by GitHub
/// Actions for the server's audience, and current; anything else refused,
/// saying why. A test's own key and key set stand for GitHub's.
final class OIDCTests: XCTestCase {
    private let audience = "applications-server"

    /// Why verifying failed, or nil when it did not.
    private func refusal(_ oidc: GitHubOIDC, _ token: String, audience: String? = nil, now: Date = Date()) async -> String? {
        do {
            _ = try await oidc.verify(token, audience: audience ?? self.audience, now: now)
            return nil
        } catch {
            return "\(error)"
        }
    }

    func testAGoodTokenSaysItsClaims() async throws {
        let key = try TestToken.key(kid: "k1")
        let keys = TestToken.jwks([key])
        let oidc = GitHubOIDC(fetch: { keys })
        let token = try TestToken.token(TestToken.claims(ref: "refs/pull/12/merge", event: "pull_request", actor: "agent-app[bot]",
                                                         headRef: "ci-signing"), key: key)
        XCTAssertTrue(GitHubOIDC.isToken(token))
        XCTAssertFalse(GitHubOIDC.isToken("amber-birch-cedar-1234"), "a password is not a token")
        let claims = try await oidc.verify(token, audience: audience)
        XCTAssertEqual(claims.repository, "AttilaTheFun/visor")
        XCTAssertEqual(claims.repositoryID, "1000")
        XCTAssertEqual(claims.ref, "refs/pull/12/merge")
        XCTAssertEqual(claims.refType, "branch")
        XCTAssertEqual(claims.sha, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(claims.eventName, "pull_request")
        XCTAssertEqual(claims.actor, "agent-app[bot]")
        XCTAssertEqual(claims.runID, "4242")
        XCTAssertEqual(claims.workflowRef, "AttilaTheFun/visor/.github/workflows/ci.yml@refs/pull/12/merge")
        XCTAssertEqual(claims.pullRequest, 12)
        XCTAssertEqual(claims.branch, "ci-signing")
        XCTAssertNil(claims.tag)
        // An audience among several is one.
        var several = TestToken.claims()
        several["aud"] = ["another", audience]
        let main = try await oidc.verify(try TestToken.token(several, key: key), audience: audience)
        XCTAssertEqual(main.branch, "main")
        XCTAssertNil(main.pullRequest)
        // GitHub's repository_id is a string; a number is read as one.
        var numbered = TestToken.claims()
        numbered["repository_id"] = 1_234
        let read = try await oidc.verify(try TestToken.token(numbered, key: key), audience: audience)
        XCTAssertEqual(read.repositoryID, "1234")
        // A token that says no repository number is not one the server can pin.
        var unnumbered = TestToken.claims()
        unnumbered.removeValue(forKey: "repository_id")
        let said = await refusal(oidc, try TestToken.token(unnumbered, key: key))
        XCTAssertEqual(said, "It says no repository_id")
    }

    func testAnExpiredTokenIsRefused() async throws {
        let key = try TestToken.key(kid: "k1")
        let keys = TestToken.jwks([key])
        let oidc = GitHubOIDC(fetch: { keys })
        let then = Date().addingTimeInterval(-3_600)
        let expired = try TestToken.token(TestToken.claims(now: then), key: key)
        let said = await refusal(oidc, expired)
        XCTAssertTrue(said?.contains("expired") == true, said ?? "verified")
        // Within the clocks' leeway it is still good.
        let lately = try TestToken.token(TestToken.claims(now: Date().addingTimeInterval(-330)), key: key)
        let leeway = await refusal(oidc, lately)
        XCTAssertNil(leeway)
        // Nor is one not yet good taken.
        let early = try TestToken.token(TestToken.claims(now: Date().addingTimeInterval(600)), key: key)
        let notYet = await refusal(oidc, early)
        XCTAssertTrue(notYet?.contains("not good before") == true, notYet ?? "verified")
    }

    func testATokenForAnotherAudienceIsRefused() async throws {
        let key = try TestToken.key(kid: "k1")
        let keys = TestToken.jwks([key])
        let oidc = GitHubOIDC(fetch: { keys })
        let token = try TestToken.token(TestToken.claims(audience: "https://github.com/AttilaTheFun"), key: key)
        let said = await refusal(oidc, token)
        XCTAssertTrue(said?.contains("not this server's audience") == true, said ?? "verified")
        // The server's own audience, if set to another.
        let ours = await refusal(oidc, try TestToken.token(TestToken.claims(audience: "applications-other"), key: key), audience: "applications-other")
        XCTAssertNil(ours)
    }

    func testATokenFromAnotherIssuerIsRefused() async throws {
        let key = try TestToken.key(kid: "k1")
        let keys = TestToken.jwks([key])
        let oidc = GitHubOIDC(fetch: { keys })
        let token = try TestToken.token(TestToken.claims(issuer: "https://token.example.com"), key: key)
        let said = await refusal(oidc, token)
        XCTAssertTrue(said?.contains("not GitHub Actions") == true, said ?? "verified")
    }

    /// Signed by a key that is not the one it names, changed after it was
    /// signed, or signed with another algorithm: refused.
    func testABadSignatureIsRefused() async throws {
        let key = try TestToken.key(kid: "k1")
        let other = try TestToken.key(kid: "k2")
        let keys = TestToken.jwks([key])
        let oidc = GitHubOIDC(fetch: { keys })
        let forged = try TestToken.token(TestToken.claims(), key: other, kid: "k1")
        let said = await refusal(oidc, forged)
        XCTAssertEqual(said, "Its signature does not verify")
        // The claims changed after signing: a release by the owner, said of a
        // pull request's token.
        let token = try TestToken.token(TestToken.claims(ref: "refs/pull/3/merge", event: "pull_request"), key: key)
        let parts = token.split(separator: ".").map(String.init)
        let changed = TestToken.base64URL(try JSONSerialization.data(withJSONObject: TestToken.claims(ref: "refs/tags/v1.0.0", refType: "tag",
                                                                                                    event: "release")))
        let tampered = await refusal(oidc, [parts[0], changed, parts[2]].joined(separator: "."))
        XCTAssertEqual(tampered, "Its signature does not verify")
        let unsigned = await refusal(oidc, try TestToken.token(TestToken.claims(), key: key, algorithm: "none"))
        XCTAssertTrue(unsigned?.contains("not RS256") == true, unsigned ?? "verified")
        let garbage = await refusal(oidc, "eyJ.not.a-token")
        XCTAssertNotNil(garbage)
    }

    /// GitHub's keys are fetched once, and again when a token names one
    /// not among them (GitHub has rotated), at most once a minute.
    func testAnUnknownKeySendsForGitHubsKeysAgain() async throws {
        let first = try TestToken.key(kid: "k1")
        let next = try TestToken.key(kid: "k2")
        let source = KeySource(TestToken.jwks([first]))
        let oidc = GitHubOIDC(fetch: { await source.fetch() })
        let now = Date()
        _ = try await oidc.verify(try TestToken.token(TestToken.claims(now: now), key: first), audience: audience, now: now)
        _ = try await oidc.verify(try TestToken.token(TestToken.claims(now: now), key: first), audience: audience, now: now)
        let once = await source.fetches
        XCTAssertEqual(once, 1, "kept")
        await source.change(to: TestToken.jwks([first, next]))
        // Within the minute, a key not listed is not sent for.
        let soon = await refusal(oidc, try TestToken.token(TestToken.claims(now: now), key: next), now: now.addingTimeInterval(10))
        XCTAssertTrue(soon?.contains("a key GitHub does not list") == true, soon ?? "verified")
        let later = now.addingTimeInterval(120)
        let claims = try await oidc.verify(try TestToken.token(TestToken.claims(now: later), key: next), audience: audience, now: later)
        XCTAssertEqual(claims.repository, "AttilaTheFun/visor")
        XCTAssertEqual(claims.repositoryID, "1000")
        let twice = await source.fetches
        XCTAssertEqual(twice, 2)
    }

    /// A JWK's modulus and exponent are the RSAPublicKey Security reads
    /// back: the same integers.
    func testAKeysModulusAndExponentMakeItsDER() throws {
        let key = try TestToken.key(kid: "k1")
        let n = try XCTUnwrap(key.jwk["n"].flatMap(GitHubOIDC.base64URL))
        let e = try XCTUnwrap(key.jwk["e"].flatMap(GitHubOIDC.base64URL))
        let der = GitHubOIDC.rsaPublicKey(modulus: n, exponent: e)
        XCTAssertEqual(TestToken.integers(der), [n, e])
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key.privateKey))
        XCTAssertEqual(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?, der)
    }
}
