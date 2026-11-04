import ApplicationsProtocol
import Foundation
import PipelineClient
import PipelineHTTP
import PipelineServer
import XCTest
@testable import ApplicationsServer

/// A release made production by promotion (`POST /api/promote`): main's
/// Alphas of the release's commit copied, stamped Production and signed
/// again for production, with a release's token alone.
final class PromotionTests: XCTestCase {
    private struct Setup {
        let server: ApplicationsServer
        let folder: URL
        let key: TestToken.Key
        let signing: FakeCodeSigning
    }

    private let commit = "0123456789abcdef0123456789abcdef01234567"

    private func makeServer() async throws -> Setup {
        let folder = TestIPA.folder()
        let paths = ServerPaths(root: folder.appendingPathComponent("support"))
        try paths.prepare()
        try ServerConfig(id: "test", name: "Test Mac", password: "secret",
                         repositories: ["AttilaTheFun/visor": ["com.example.Visor", "com.example.VisorMac"],
                                        "AttilaTheFun/noson": ["com.example.Noson"]],
                         releasers: ["AttilaTheFun"]).save(to: paths.config)
        for kind in ["development", "ad hoc"] { try TestProfile.write(in: paths.profiles, bundleID: "com.example.Visor", kind: kind) }
        let key = try TestToken.key(kid: "k1")
        let keys = TestToken.jwks([key])
        let signing = FakeCodeSigning(adHoc: true)
        let server = try ApplicationsServer(paths: paths, name: "Test Mac", codeSigning: signing,
                                            notary: FakeNotary(accepts: true, events: signing.events), oidc: GitHubOIDC(fetch: { keys }))
        try await server.prepareTLS(local: [LocalAddress(ip: "192.0.2.52", overlay: false)], hostName: "test-mac.local")
        return Setup(server: server, folder: folder, key: key, signing: signing)
    }

    private func said(_ response: HTTPResponse) -> String {
        (try? JSONDecoder().decode([String: String].self, from: response.data))?["error"] ?? ""
    }

    private func post(_ setup: Setup, _ path: String, token: String, headers: [String: String] = [:], body: URL? = nil) async -> HTTPResponse {
        var headers = headers
        headers["authorization"] = "Bearer " + token
        return await setup.server.handle(HTTPRequest(method: "POST", path: path, headers: headers, bodyFile: body, secure: true))
    }

    /// Main's Alphas of the commit, as its CI publishes them.
    private func publishAlphas(_ setup: Setup) async throws -> [Build] {
        let main = try TestToken.token(TestToken.claims(sha: commit), key: setup.key)
        var alphas: [Build] = []
        for package in [try TestIPA.make(in: setup.folder, version: "0.23.4", build: "4", variant: "Alpha"),
                        try TestMacApp.make(in: setup.folder, version: "0.23.4", build: "4", variant: "Alpha")] {
            let published = await post(setup, "/api/publish", token: main, body: package)
            XCTAssertEqual(published.status, 201, String(decoding: published.data, as: UTF8.self))
            alphas.append(try WireCoding.decoder().decode(Build.self, from: published.data))
        }
        return alphas
    }

    /// The release's token promotes the commit's Alphas: each a production
    /// build of the same version, stamped Production, the iPhone app's
    /// signed with the distribution identity and its ad hoc profile and
    /// given its scheme, the Mac app's notarized; asked again, the same.
    func testAReleasePromotesItsCommitsAlphas() async throws {
        let setup = try await makeServer()
        let alphas = try await publishAlphas(setup)
        XCTAssertEqual(alphas.map(\.channel), [.beta, .beta])
        let signedBefore = setup.signing.signed.count
        let release = try TestToken.token(TestToken.claims(ref: "refs/tags/v0.23.4", refType: "tag", event: "release", sha: commit),
                                          key: setup.key)
        let notes = Data("Visor 0.23.4".utf8).base64EncodedString()
        let promoted = await post(setup, "/api/promote", token: release, headers: ["x-applications-notes": notes])
        XCTAssertEqual(promoted.status, 201, String(decoding: promoted.data, as: UTF8.self))
        let builds = try WireCoding.decoder().decode([Build].self, from: promoted.data)
        XCTAssertEqual(Set(builds.map(\.platform)), ["ios", "macos"])
        for build in builds {
            XCTAssertEqual(build.channel, .production)
            XCTAssertEqual(build.buildVariant, "Production")
            XCTAssertEqual(build.version, "0.23.4")
            XCTAssertEqual(build.notes, "Visor 0.23.4")
            XCTAssertEqual(build.origin, BuildOrigin(commit: commit))
            XCTAssertFalse(alphas.contains { $0.id == build.id })
            let kept = await setup.server.builds.package(build.id)
            XCTAssertEqual(try IPAMetadata.read(try XCTUnwrap(kept)).buildVariant, "Production")
        }
        let phone = try XCTUnwrap(builds.first { $0.platform == "ios" })
        XCTAssertEqual(phone.buildScheme, BuildSchemes.scheme(release: BuildStore.ownRelease, number: 1))
        let resigned = setup.signing.signed.dropFirst(signedBefore)
        XCTAssertEqual(resigned.first { $0.path == "Visor.app" && $0.identity == TestProfile.sha1(.distribution) }?.profile,
                       TestProfile.name("ad hoc", "com.example.Visor"))
        XCTAssertTrue(resigned.contains { $0.identity == TestProfile.sha1(.developerID) && $0.hardenedRuntime })
        // The Alphas stay as they were.
        for alpha in alphas {
            let kept = await setup.server.builds.package(alpha.id)
            XCTAssertEqual(try IPAMetadata.read(try XCTUnwrap(kept)).buildVariant, "Alpha")
        }
        let again = await post(setup, "/api/promote", token: release)
        XCTAssertEqual(again.status, 201, String(decoding: again.data, as: UTF8.self))
        XCTAssertEqual(Set(try WireCoding.decoder().decode([Build].self, from: again.data).map(\.id)), Set(builds.map(\.id)))
        let all = await setup.server.builds.all()
        XCTAssertEqual(all.count, 4)
    }

    /// Only a release's token promotes, and only what its commit has:
    /// main's token, a tag someone else pushed, or another repository's
    /// token is refused; a commit with no Alpha here is not found.
    func testWhatIsNotAReleaseIsNotPromoted() async throws {
        let setup = try await makeServer()
        _ = try await publishAlphas(setup)
        let signedBefore = setup.signing.signed.count
        let main = await post(setup, "/api/promote", token: try TestToken.token(TestToken.claims(sha: commit), key: setup.key))
        XCTAssertEqual(main.status, 403)
        XCTAssertTrue(said(main).contains("not a release's tag"), said(main))
        let byBot = try TestToken.token(TestToken.claims(ref: "refs/tags/v0.23.4", refType: "tag", event: "push", actor: "agent-app[bot]",
                                                         sha: commit), key: setup.key)
        let bot = await post(setup, "/api/promote", token: byBot)
        XCTAssertEqual(bot.status, 403)
        XCTAssertTrue(said(bot).contains("not a releaser"), said(bot))
        let noson = try TestToken.token(TestToken.claims(repository: "AttilaTheFun/noson", ref: "refs/tags/v0.23.4", refType: "tag",
                                                         event: "release", sha: commit), key: setup.key)
        let another = await post(setup, "/api/promote", token: noson)
        XCTAssertEqual(another.status, 404, "Visor's Alphas are not Noson's")
        let other = try TestToken.token(TestToken.claims(ref: "refs/tags/v0.23.5", refType: "tag", event: "release",
                                                         sha: "fedcba9876543210fedcba9876543210fedcba98"), key: setup.key)
        let missing = await post(setup, "/api/promote", token: other)
        XCTAssertEqual(missing.status, 404)
        XCTAssertTrue(said(missing).contains("No Alpha of fedcba9876543210fedcba9876543210fedcba98"), said(missing))
        XCTAssertEqual(setup.signing.signed.count, signedBefore, "nothing signed")
        let all = await setup.server.builds.all()
        XCTAssertEqual(all.count, 2)
    }
}
