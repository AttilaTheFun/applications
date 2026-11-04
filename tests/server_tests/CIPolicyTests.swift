import ApplicationsProtocol
import Foundation
import PipelineClient
import PipelineHTTP
import PipelineServer
import XCTest
@testable import ApplicationsServer

/// What a CI job may publish, and as what, by its verified token
/// (CIPolicy): its own repository's apps alone; a release of a v* tag by a
/// releaser as production; a branch, a pull request or main as a beta; a
/// tag anyone else released, refused.
final class CIPolicyTests: XCTestCase {
    private let policy = CIPolicy(repositories: ["AttilaTheFun/visor": ["com.LoganShire.Visor", "com.LoganShire.Visor.Mac"],
                                                 "example/notes": ["com.LoganShire.Notes"]],
                                  releasers: ["AttilaTheFun"])

    private func claims(repository: String = "AttilaTheFun/visor", ref: String = "refs/heads/main", refType: String = "branch",
                        event: String = "push", actor: String = "AttilaTheFun", headRef: String = "") -> CIClaims {
        CIClaims(repository: repository, ref: ref, refType: refType, sha: "0123456789abcdef0123456789abcdef01234567", eventName: event,
                 actor: actor, runID: "4242", workflowRef: "\(repository)/.github/workflows/ci.yml@\(ref)", headRef: headRef)
    }

    private func refusal(_ claims: CIClaims, _ bundleID: String) -> String? {
        do {
            _ = try policy.channel(for: claims, bundleID: bundleID)
            return nil
        } catch {
            return "\(error)"
        }
    }

    func testAnUnconfiguredRepositoryPublishesNothing() {
        let said = refusal(claims(repository: "AttilaTheFun/oss"), "com.LoganShire.OSServer")
        XCTAssertEqual(said, "AttilaTheFun/oss publishes nothing here: on the server's Mac, applications-server repo AttilaTheFun/oss <bundle id>…")
        XCTAssertNotNil(refusal(claims(repository: "someone/visor"), "com.LoganShire.Visor"))
    }

    /// One repository never publishes another's app, as a beta or a
    /// release, nor an app no repository has.
    func testABundleIDOfAnotherRepositoryIsRefused() {
        let said = refusal(claims(), "com.LoganShire.Notes.Beta")
        XCTAssertTrue(said?.hasPrefix("com.LoganShire.Notes.Beta is example/notes's, not AttilaTheFun/visor's") == true, said ?? "taken")
        let release = refusal(claims(ref: "refs/tags/v0.42.1", refType: "tag", event: "release"), "com.LoganShire.Notes")
        XCTAssertTrue(release?.contains("example/notes's") == true, release ?? "taken")
        let nobodys = refusal(claims(), "com.LoganShire.Noson")
        XCTAssertTrue(nobodys?.hasPrefix("com.LoganShire.Noson is no repository's") == true, nobodys ?? "taken")
        // The repository's name in another case is the same repository.
        XCTAssertEqual(try policy.channel(for: claims(repository: "attilathefun/VISOR"), bundleID: "com.LoganShire.Visor.Beta"), .beta)
    }

    /// A pull request's build is a beta, its beta's bundle id or its
    /// production's (Visor builds commits with its production ids until it
    /// takes up the variants), whoever opened it.
    func testAPullRequestsBuildIsABeta() throws {
        let pullRequest = claims(ref: "refs/pull/12/merge", event: "pull_request", actor: "agent-app[bot]", headRef: "ci-signing")
        XCTAssertEqual(try policy.channel(for: pullRequest, bundleID: "com.LoganShire.Visor.Beta"), .beta)
        XCTAssertEqual(try policy.channel(for: pullRequest, bundleID: "com.LoganShire.Visor"), .beta)
        XCTAssertEqual(try policy.channel(for: pullRequest, bundleID: "com.LoganShire.Visor.Mac.Beta"), .beta)
        // Main's and a branch's pushes, and a run started by hand, are betas too.
        XCTAssertEqual(try policy.channel(for: claims(), bundleID: "com.LoganShire.Visor"), .beta)
        XCTAssertEqual(try policy.channel(for: claims(ref: "refs/heads/ci-signing", actor: "agent-app[bot]"),
                                          bundleID: "com.LoganShire.Visor.Beta"), .beta)
        XCTAssertEqual(try policy.channel(for: claims(event: "workflow_dispatch"), bundleID: "com.LoganShire.Visor"), .beta)
    }

    /// The owner's release (publishing the draft, which makes its tag) is
    /// production; so is the owner's push of a v* tag. The owner's login
    /// in any case.
    func testAReleaseByTheOwnerIsProduction() throws {
        let release = claims(ref: "refs/tags/v0.42.1", refType: "tag", event: "release")
        XCTAssertEqual(try policy.channel(for: release, bundleID: "com.LoganShire.Visor"), .production)
        XCTAssertEqual(try policy.channel(for: release, bundleID: "com.LoganShire.Visor.Mac"), .production)
        XCTAssertEqual(try policy.channel(for: claims(ref: "refs/tags/v0.42.1", refType: "tag", event: "push", actor: "attilathefun"),
                                          bundleID: "com.LoganShire.Visor"), .production)
    }

    /// A v* tag released or pushed by anyone else is refused, not made a
    /// beta: its build is production's (--config=prod), and a beta of it
    /// would hide that nobody approved it.
    func testATagPushedBySomeoneElseIsRefused() {
        let pushed = refusal(claims(ref: "refs/tags/v0.42.1", refType: "tag", event: "push", actor: "agent-app[bot]"),
                             "com.LoganShire.Visor")
        XCTAssertEqual(pushed, "v0.42.1 was released by agent-app[bot], who is not a releaser here (applications-server releaser "
                       + "<login>): its build is not published, as production or as a beta")
        XCTAssertNotNil(refusal(claims(ref: "refs/tags/v0.42.1", refType: "tag", event: "release", actor: "someone"), "com.LoganShire.Visor.Beta"))
        // Nor is a tag that is not a release's, or a v* tag's run of
        // another event.
        let inbox = refusal(claims(ref: "refs/tags/inbox", refType: "tag", event: "push"), "com.LoganShire.Visor")
        XCTAssertTrue(inbox?.hasPrefix("inbox is a tag, and only a release's") == true, inbox ?? "taken")
        let byHand = refusal(claims(ref: "refs/tags/v0.42.1", refType: "tag", event: "workflow_dispatch"), "com.LoganShire.Visor")
        XCTAssertTrue(byHand?.contains("a workflow_dispatch event") == true, byHand ?? "taken")
    }

    /// A release branch (release-MAJOR-MINOR, cut from a commit of main)
    /// pushed by a releaser is production; by anyone else it's refused, and
    /// a branch merely named release-something is an Alpha's like any other.
    func testAReleaseBranchPushedByTheOwnerIsProduction() throws {
        XCTAssertEqual(try policy.channel(for: claims(ref: "refs/heads/release-0-42"), bundleID: "com.LoganShire.Visor"), .production)
        XCTAssertEqual(try policy.channel(for: claims(ref: "refs/heads/release-0-42", actor: "attilathefun"), bundleID: "com.LoganShire.Visor"),
                       .production)
        let byAgent = refusal(claims(ref: "refs/heads/release-0-42", actor: "agent-app[bot]"), "com.LoganShire.Visor")
        XCTAssertEqual(byAgent, "release-0-42 was pushed by agent-app[bot], who is not a releaser here (applications-server releaser "
                       + "<login>): its build is not published, as production or as a beta")
        XCTAssertNotNil(refusal(claims(ref: "refs/heads/release-0-42", event: "workflow_dispatch"), "com.LoganShire.Visor"))
        XCTAssertEqual(try policy.channel(for: claims(ref: "refs/heads/release-notes"), bundleID: "com.LoganShire.Visor"), .beta)
        XCTAssertEqual(CIPolicy.releaseLine("release-0-42"), "0.42")
        XCTAssertNil(CIPolicy.releaseLine("release-0-42-1"))
    }

    /// A build's BuildVariant against its publish: Production only from its
    /// release branch, of that branch's MAJOR.MINOR; an Alpha never as production.
    func testABuildsVariantMustMatchItsPublish() throws {
        let release = claims(ref: "refs/heads/release-0-42")
        XCTAssertNoThrow(try CIPolicy.checkVariant("Production", version: "0.42.17", channel: .production, claims: release))
        XCTAssertThrowsError(try CIPolicy.checkVariant("Alpha", version: "0.42.17", channel: .production, claims: release))
        XCTAssertThrowsError(try CIPolicy.checkVariant("Production", version: "0.43.2", channel: .production, claims: release))
        XCTAssertThrowsError(try CIPolicy.checkVariant("Production", version: "0.42.17", channel: .beta, claims: claims()))
        XCTAssertNoThrow(try CIPolicy.checkVariant("Alpha", version: "0.42.17", channel: .beta, claims: claims()))
        // AdHoc: a branch's, built by hand; never main's, a release branch's or a push's.
        let byHand = claims(ref: "refs/heads/idea", event: "workflow_dispatch")
        XCTAssertNoThrow(try CIPolicy.checkVariant("AdHoc", version: "0.42.17", channel: .beta, claims: byHand))
        XCTAssertThrowsError(try CIPolicy.checkVariant("AdHoc", version: "0.42.17", channel: .beta, claims: claims(ref: "refs/heads/idea")))
        XCTAssertThrowsError(try CIPolicy.checkVariant("AdHoc", version: "0.42.17", channel: .beta,
                                                       claims: claims(ref: "refs/heads/main", event: "workflow_dispatch")))
        // An app not yet building with a variant is let be.
        XCTAssertNoThrow(try CIPolicy.checkVariant(nil, version: "0.42.17", channel: .production, claims: release))
    }

    /// A release publishes production builds: a beta's bundle id from a
    /// release's tag (built without --config=prod) is refused, saying so.
    func testABetasBundleIDIsRefusedWithARelease() {
        let said = refusal(claims(ref: "refs/tags/v0.42.1", refType: "tag", event: "release"), "com.LoganShire.Visor.Beta")
        XCTAssertEqual(said, "com.LoganShire.Visor.Beta is a beta's bundle id, and a release publishes the production build, "
                       + "com.LoganShire.Visor (built with --config=prod)")
    }
}

/// Publishing from CI through the API: the token in place of the password,
/// the build signed here (a fake codesign that signs ad hoc, so the check
/// after signing passes) with the profile its channel takes, and refused
/// when the token or the build is not one this server takes.
final class CIPublishTests: XCTestCase {
    private struct Setup {
        let server: ApplicationsServer
        let folder: URL
        let key: TestToken.Key
        let signing: FakeCodeSigning
    }

    private func makeServer() async throws -> Setup {
        let folder = TestIPA.folder()
        let paths = ServerPaths(root: folder.appendingPathComponent("support"))
        try paths.prepare()
        try ServerConfig(id: "test", name: "Test Mac", password: "secret",
                         repositories: ["AttilaTheFun/visor": ["com.example.Visor"], "AttilaTheFun/noson": ["com.example.Noson"]],
                         releasers: ["AttilaTheFun"]).save(to: paths.config)
        for (bundleID, kind) in [("com.example.Visor.Beta", "development"), ("com.example.Visor", "development"),
                                 ("com.example.Visor", "ad hoc")] {
            try TestProfile.write(in: paths.profiles, bundleID: bundleID, kind: kind)
        }
        let key = try TestToken.key(kid: "k1")
        let keys = TestToken.jwks([key])
        let signing = FakeCodeSigning(adHoc: true)
        let server = try ApplicationsServer(paths: paths, name: "Test Mac", codeSigning: signing,
                                            notary: FakeNotary(accepts: true, events: signing.events), oidc: GitHubOIDC(fetch: { keys }))
        try await server.prepareTLS(local: [LocalAddress(ip: "192.0.2.52", overlay: false)], hostName: "test-mac.local")
        return Setup(server: server, folder: folder, key: key, signing: signing)
    }

    /// What a refusal says (its JSON's error).
    private func said(_ response: HTTPResponse) -> String {
        (try? JSONDecoder().decode([String: String].self, from: response.data))?["error"] ?? ""
    }

    private func publish(_ setup: Setup, _ package: URL, token: String, headers: [String: String] = [:], secure: Bool = true) async -> HTTPResponse {
        var headers = headers
        headers["authorization"] = "Bearer " + token
        return await setup.server.handle(HTTPRequest(method: "POST", path: "/api/publish", headers: headers, bodyFile: package, secure: secure))
    }

    /// A pull request's beta, sent with its token and no password, is
    /// signed with the development identity and the beta's own profile,
    /// and kept as its pull request's.
    func testAPullRequestsBetaIsSignedWithItsDevelopmentProfile() async throws {
        let setup = try await makeServer()
        let token = try TestToken.token(TestToken.claims(ref: "refs/pull/7/merge", event: "pull_request", actor: "agent-app[bot]",
                                                         headRef: "ci-signing"), key: setup.key)
        let ipa = try TestIPA.make(in: setup.folder, bundleID: "com.example.Visor.Beta", name: "Visor β")
        let head = "fedcba9876543210fedcba9876543210fedcba98"
        let published = await publish(setup, ipa, token: token, headers: ["x-applications-commit": head])
        XCTAssertEqual(published.status, 201, String(decoding: published.data, as: UTF8.self))
        let build = try WireCoding.decoder().decode(Build.self, from: published.data)
        XCTAssertEqual(build.channel, .beta)
        XCTAssertNil(build.buildScheme)
        XCTAssertEqual(build.origin, BuildOrigin(commit: head, branch: "ci-signing", pullRequest: 7))
        XCTAssertEqual(setup.signing.signed, [FakeCodeSigning.Signed(
            path: "Visor β.app", identity: TestProfile.sha1(.development), hardenedRuntime: false, timestamp: false,
            applicationIdentifier: "\(TestProfile.team).com.example.Visor.Beta", debuggable: true,
            profile: TestProfile.name("development", "com.example.Visor.Beta"))])
        let kept = await setup.server.builds.package(build.id)
        let package = try XCTUnwrap(kept)
        let embedded = try ProcessRunner.run("/usr/bin/unzip", ["-p", package.path, "Payload/Visor β.app/embedded.mobileprovision"])
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: embedded, format: nil) as? [String: Any])
        XCTAssertEqual(profile["Name"] as? String, TestProfile.name("development", "com.example.Visor.Beta"))
    }

    /// The owner's release is production: signed with the distribution
    /// identity and the ad hoc profile, its scheme given and added as it
    /// is signed, its commit the tag's.
    func testTheOwnersReleaseIsSignedForProductionWithItsScheme() async throws {
        let setup = try await makeServer()
        let token = try TestToken.token(TestToken.claims(ref: "refs/tags/v0.23.1", refType: "tag", event: "release"), key: setup.key)
        let published = await publish(setup, try TestIPA.make(in: setup.folder, version: "0.23.1", build: "1"), token: token,
                                      headers: ["x-applications-release": "false"])
        XCTAssertEqual(published.status, 201, String(decoding: published.data, as: UTF8.self))
        let build = try WireCoding.decoder().decode(Build.self, from: published.data)
        XCTAssertEqual(build.channel, .production, "the token decides, not the header")
        let scheme = BuildSchemes.scheme(release: BuildStore.ownRelease, number: 1)
        XCTAssertEqual(build.buildScheme, scheme)
        XCTAssertEqual(build.origin, BuildOrigin(commit: "0123456789abcdef0123456789abcdef01234567"))
        XCTAssertEqual(setup.signing.signed.map(\.identity), [TestProfile.sha1(.distribution)])
        XCTAssertEqual(setup.signing.signed.first?.profile, TestProfile.name("ad hoc", "com.example.Visor"))
        XCTAssertEqual(setup.signing.signed.first?.debuggable, false)
        let kept = await setup.server.builds.package(build.id)
        let package = try XCTUnwrap(kept)
        XCTAssertEqual(try IPAMetadata.read(package).urlSchemes, ["testapp", scheme])
    }

    /// Production comes from a published release's CI alone, and from
    /// nothing else the server asks: main's build of a commit, under the
    /// production bundle id, stays a beta; the release of that commit's tag
    /// is production, at once, beside it; the beta stays a beta.
    func testOnlyAReleasesPublishIsProduction() async throws {
        let setup = try await makeServer()
        let main = try TestToken.token(TestToken.claims(), key: setup.key)
        let beta = await publish(setup, try TestIPA.make(in: setup.folder, version: "0.23.1", build: "1"), token: main,
                                 headers: ["x-applications-release": "true"])
        XCTAssertEqual(beta.status, 201, String(decoding: beta.data, as: UTF8.self))
        XCTAssertEqual(try WireCoding.decoder().decode(Build.self, from: beta.data).channel, .beta, "the token decides, not the header")
        for event in ["workflow_dispatch", "pull_request"] {
            let token = try TestToken.token(TestToken.claims(event: event), key: setup.key)
            let published = await publish(setup, try TestIPA.make(in: setup.folder, version: "0.23.1", build: "1"), token: token)
            XCTAssertEqual(published.status, 201, String(decoding: published.data, as: UTF8.self))
            XCTAssertEqual(try WireCoding.decoder().decode(Build.self, from: published.data).channel, .beta, event)
        }
        let release = try TestToken.token(TestToken.claims(ref: "refs/tags/v0.23.1", refType: "tag", event: "release"), key: setup.key)
        let production = await publish(setup, try TestIPA.make(in: setup.folder, version: "0.23.1", build: "1"), token: release)
        XCTAssertEqual(production.status, 201, String(decoding: production.data, as: UTF8.self))
        let released = try WireCoding.decoder().decode(Build.self, from: production.data)
        XCTAssertEqual(released.channel, .production)
        let listed = await setup.server.handle(HTTPRequest(method: "GET", path: "/api/apps", headers: ["authorization": "Bearer secret"],
                                                           secure: true))
        XCTAssertEqual(listed.status, 200)
        let apps = try WireCoding.decoder().decode([AppBuilds].self, from: listed.data)
        let channels = apps.flatMap(\.builds).map { "\($0.version) \($0.channel?.rawValue ?? "none")" }
        XCTAssertEqual(channels.filter { $0.hasSuffix("production") }, ["0.23.1 production"])
        XCTAssertTrue(apps.flatMap(\.builds).contains { $0.id == released.id && $0.channel == .production })
    }

    /// No token the server takes, or a build its token may not publish:
    /// refused, saying why, and nothing kept or signed.
    func testWhatATokenMayNotPublishIsRefused() async throws {
        let setup = try await makeServer()
        let ipa = { try TestIPA.make(in: setup.folder) }
        let elsewhere = try TestToken.token(TestToken.claims(audience: "somewhere-else"), key: setup.key)
        let wrongAudience = await publish(setup, try ipa(), token: elsewhere)
        XCTAssertEqual(wrongAudience.status, 401)
        XCTAssertTrue(said(wrongAudience).contains("The token was refused"))
        let plain = await publish(setup, try ipa(), token: try TestToken.token(TestToken.claims(), key: setup.key), secure: false)
        XCTAssertEqual(plain.status, 404, "HTTPS only")
        let byBot = try TestToken.token(TestToken.claims(ref: "refs/tags/v0.23.1", refType: "tag", event: "push",
                                                         actor: "agent-app[bot]"), key: setup.key)
        let tagged = await publish(setup, try ipa(), token: byBot)
        XCTAssertEqual(tagged.status, 403)
        XCTAssertTrue(said(tagged).contains("not a releaser"))
        let noson = try TestToken.token(TestToken.claims(repository: "AttilaTheFun/noson"), key: setup.key)
        let another = await publish(setup, try ipa(), token: noson)
        XCTAssertEqual(another.status, 403)
        XCTAssertTrue(said(another).contains("com.example.Visor is AttilaTheFun/visor's, not AttilaTheFun/noson's"))
        // A beta whose bundle id has no profile here: refused, naming it.
        let noProfile = await publish(setup, try TestIPA.make(in: setup.folder, bundleID: "com.example.Noson.Beta", name: "Noson β"),
                                      token: noson)
        XCTAssertEqual(noProfile.status, 400)
        XCTAssertTrue(said(noProfile).contains("No development profile for com.example.Noson.Beta"))
        let kept = await setup.server.builds.all()
        XCTAssertEqual(kept, [])
        XCTAssertEqual(setup.signing.signed, [])
    }

    /// A repository's number at GitHub is pinned by its first token, and a
    /// repository given its name later (another number) publishes nothing,
    /// nor is numbered; `applications-server repo` again lets go of it.
    func testARepositorysNumberIsPinnedByItsFirstToken() async throws {
        let setup = try await makeServer()
        let first = try TestToken.token(TestToken.claims(repositoryID: "1000"), key: setup.key)
        let published = await publish(setup, try TestIPA.make(in: setup.folder), token: first)
        XCTAssertEqual(published.status, 201, String(decoding: published.data, as: UTF8.self))
        let pinned = await setup.server.config.repositoryIDs
        XCTAssertEqual(pinned, ["attilathefun/visor": "1000"])
        XCTAssertEqual(ServerConfig.load(setup.server.paths.config)?.repositoryIDs, ["attilathefun/visor": "1000"], "kept")
        let usurper = try TestToken.token(TestToken.claims(repositoryID: "2000"), key: setup.key)
        let refused = await publish(setup, try TestIPA.make(in: setup.folder), token: usurper)
        XCTAssertEqual(refused.status, 403)
        XCTAssertTrue(said(refused).contains("AttilaTheFun/visor is repository 2000 at GitHub, not 1000"), said(refused))
        let numbered = await setup.server.handle(HTTPRequest(method: "POST", path: "/api/next-version",
                                                             headers: ["authorization": "Bearer " + usurper],
                                                             body: Data(#"{"app":"Visor","line":"0.23"}"#.utf8), secure: true))
        XCTAssertEqual(numbered.status, 403)
        let kept = await setup.server.builds.all()
        XCTAssertEqual(kept.count, 1)
        try await setup.server.setRepository("AttilaTheFun/visor", bundleIDs: ["com.example.Visor"])
        let again = await publish(setup, try TestIPA.make(in: setup.folder), token: usurper)
        XCTAssertEqual(again.status, 201, String(decoding: again.data, as: UTF8.self))
        let repinned = await setup.server.config.repositoryIDs
        XCTAssertEqual(repinned, ["attilathefun/visor": "2000"])
    }

    /// The password still publishes by hand, as before, unsigned by the
    /// server; CI's code carries no password.
    func testThePasswordStillPublishesAndCIsCodeHasNone() async throws {
        let setup = try await makeServer()
        let published = await setup.server.handle(HTTPRequest(method: "POST", path: "/api/publish", headers: ["authorization": "Bearer secret"],
                                                              bodyFile: try TestIPA.make(in: setup.folder)))
        XCTAssertEqual(published.status, 201)
        XCTAssertEqual(setup.signing.signed, [])
        let code = try await setup.server.ciCode()
        XCTAssertEqual(code.addresses, ["https://192.0.2.52:7461", "https://test-mac.local:7461"])
        XCTAssertEqual(CICode(parsing: code.text), code)
        let json = String(decoding: try XCTUnwrap(GitHubOIDC.base64URL(code.text)), as: UTF8.self)
        XCTAssertFalse(json.contains("secret"))
        XCTAssertTrue(json.contains(#""addresses":["https://192.0.2.52:7461","https://test-mac.local:7461"]"#), "no escaped slashes")
    }
}
