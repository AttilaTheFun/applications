import ApplicationsProtocol
import Foundation
import PipelineClient
import PipelineHTTP
import PipelineServer
import XCTest
@testable import ApplicationsServer

/// The version CI stamps into a build before building it, over HTTPS
/// (`POST /api/next-version`): with its OIDC token, for its token's commit,
/// of one of its repository's apps; as the command line gives it, the same
/// for every build of one commit; refused, saying why, as publishing's
/// refusals are. The password asks too, for hand use.
final class NextVersionTests: XCTestCase {
    private struct Setup {
        let server: ApplicationsServer
        let key: TestToken.Key
    }

    /// Visor's repository publishes com.example.Visor, whose builds here are
    /// Visor's (a beta of 0.38.4); Noson's com.example.Noson, named Noson by
    /// apps.json before it has a build; Notes' is not configured.
    private func makeServer() async throws -> Setup {
        let folder = TestIPA.folder()
        let paths = ServerPaths(root: folder.appendingPathComponent("support"))
        try paths.prepare()
        try ServerConfig(id: "test", name: "Test Mac", password: "secret",
                         repositories: ["AttilaTheFun/visor": ["com.example.Visor"], "AttilaTheFun/noson": ["com.example.Noson"]],
                         releasers: ["AttilaTheFun"]).save(to: paths.config)
        let key = try TestToken.key(kid: "k1")
        let keys = TestToken.jwks([key])
        let server = try ApplicationsServer(paths: paths, name: "Test Mac", oidc: GitHubOIDC(fetch: { keys }))
        try await server.prepareTLS(local: [LocalAddress(ip: "192.0.2.52", overlay: false)], hostName: "test-mac.local")
        let beta = try TestIPA.make(in: folder, bundleID: "com.example.Visor.Beta", name: "Visor β", version: "0.38.4", build: "1")
        let published = await server.handle(HTTPRequest(method: "POST", path: "/api/publish", bodyFile: beta, local: true))
        XCTAssertEqual(published.status, 201, String(decoding: published.data, as: UTF8.self))
        await server.appNames.set("Noson", for: "com.example.Noson.Beta")
        return Setup(server: server, key: key)
    }

    private func ask(_ setup: Setup, _ body: [String: String], token: String? = nil, password: String? = nil, local: Bool = false,
                     secure: Bool = true) async throws -> HTTPResponse {
        var headers: [String: String] = [:]
        if let bearer = token ?? password { headers["authorization"] = "Bearer " + bearer }
        return await setup.server.handle(HTTPRequest(method: "POST", path: "/api/next-version", headers: headers,
                                                     body: try JSONSerialization.data(withJSONObject: body), local: local, secure: secure))
    }

    private func version(_ response: HTTPResponse) throws -> String {
        XCTAssertEqual(response.status, 200, String(decoding: response.data, as: UTF8.self))
        return try WireCoding.decoder().decode(NextVersionAnswer.self, from: response.data).version
    }

    /// What a refusal says (its JSON's error).
    private func said(_ response: HTTPResponse) -> String {
        (try? JSONDecoder().decode([String: String].self, from: response.data))?["error"] ?? ""
    }

    private func token(_ setup: Setup, repository: String = "AttilaTheFun/visor", ref: String = "refs/heads/main", refType: String = "branch",
                       event: String = "push", sha: String, audience: String = "applications-server") throws -> String {
        try TestToken.token(TestToken.claims(repository: repository, ref: ref, refType: refType, event: event, sha: sha, audience: audience),
                            key: setup.key)
    }

    /// A configured repository's job is given its app's next version for
    /// its token's commit (not one its body names), the same again for
    /// that commit, from any of its jobs (a pull request's, a release's),
    /// and the next for the next commit; the command line says the same.
    func testATokenIsGivenItsCommitsVersion() async throws {
        let setup = try await makeServer()
        let main = "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
        let first = try await ask(setup, ["app": "Visor", "line": "0.38", "commit": "ffff0000"], token: try token(setup, sha: main))
        XCTAssertEqual(try version(first), "0.38.5", "one past the beta of 0.38.4")
        let again = try await ask(setup, ["app": "Visor", "line": "0.38"], token: try token(setup, sha: main))
        XCTAssertEqual(try version(again), "0.38.5", "the same commit, the same version")
        // The release of that commit, its tag's run, is given the same.
        let release = try await ask(setup, ["app": "Visor", "line": "0.38"],
                                    token: try token(setup, ref: "refs/tags/v0.38.5", refType: "tag", event: "release", sha: main))
        XCTAssertEqual(try version(release), "0.38.5")
        let commandLine = await setup.server.nextVersion(app: "Visor", line: "0.38", commit: main)
        XCTAssertEqual(commandLine, "0.38.5", "as applications-server next-version --commit says")
        let next = try await ask(setup, ["app": "Visor", "line": "0.38"],
                                 token: try token(setup, ref: "refs/pull/9/merge", event: "pull_request", sha: "bbbb2222bbbb2222"))
        XCTAssertEqual(try version(next), "0.38.6")
        let numbers = await setup.server.buildNumbers(commit: "ffff0000")
        XCTAssertEqual(numbers, [], "the body's commit is not the token's")
        // An app named by apps.json, with no build yet, starts its line at 1.
        let noson = try await ask(setup, ["app": "Noson", "line": "1.2"], token: try token(setup, repository: "attilathefun/Noson", sha: main))
        XCTAssertEqual(try version(noson), "1.2.1")
    }

    /// No token the server takes is 401; a repository not configured, or
    /// an app not its bundle ids', 403; a request that is not one, 400;
    /// plain HTTP, nothing. Nothing is numbered for any of them.
    func testWhatATokenMayNotAskIsRefused() async throws {
        let setup = try await makeServer()
        let sha = "cccc3333cccc3333cccc3333cccc3333cccc3333"
        let elsewhere = try await ask(setup, ["app": "Visor", "line": "0.38"], token: try token(setup, sha: sha, audience: "somewhere-else"))
        XCTAssertEqual(elsewhere.status, 401)
        XCTAssertTrue(said(elsewhere).contains("The token was refused"), said(elsewhere))
        let notes = try await ask(setup, ["app": "Notes", "line": "0.38"], token: try token(setup, repository: "example/notes", sha: sha))
        XCTAssertEqual(notes.status, 403)
        XCTAssertTrue(said(notes).contains("example/notes publishes nothing here"), said(notes))
        let another = try await ask(setup, ["app": "Visor", "line": "0.38"], token: try token(setup, repository: "AttilaTheFun/noson", sha: sha))
        XCTAssertEqual(another.status, 403)
        XCTAssertEqual(said(another), "Refused: Visor is not AttilaTheFun/noson's: its bundle ids (com.example.Noson and their betas) are "
                       + "Noson's here, by their builds or applications-server app <bundle id> <app>")
        let unknown = try await ask(setup, ["app": "Visor β", "line": "0.38"], token: try token(setup, sha: sha))
        XCTAssertEqual(unknown.status, 403, "a beta's name is not its app's")
        let noLine = try await ask(setup, ["app": "Visor", "line": "0.38.0"], token: try token(setup, sha: sha))
        XCTAssertEqual(noLine.status, 400)
        let plain = try await ask(setup, ["app": "Visor", "line": "0.38"], token: try token(setup, sha: sha), secure: false)
        XCTAssertEqual(plain.status, 404, "HTTPS only")
        let numbers = await setup.server.buildNumbers(commit: sha)
        XCTAssertEqual(numbers, [])
    }

    /// By hand, the password asks as the command line does, for the commit
    /// its body names (or none, kept for no commit); from this computer
    /// itself, no password; without it, from elsewhere, 401.
    func testThePasswordAsksForAnyCommit() async throws {
        let setup = try await makeServer()
        let byHand = try await ask(setup, ["app": "Visor", "line": "0.38", "commit": "dddd4444"], password: "secret")
        XCTAssertEqual(try version(byHand), "0.38.5")
        let local = try await ask(setup, ["app": "Visor", "line": "0.38", "commit": "dddd4444"], local: true)
        XCTAssertEqual(try version(local), "0.38.5")
        let byToken = try await ask(setup, ["app": "Visor", "line": "0.38"], token: try token(setup, sha: "dddd4444dddd4444"))
        XCTAssertEqual(try version(byToken), "0.38.5", "a token of the same commit")
        let wrong = try await ask(setup, ["app": "Visor", "line": "0.38"], password: "guess")
        XCTAssertEqual(wrong.status, 401)
        let short = try await ask(setup, ["app": "Visor", "line": "0.38", "commit": "dddd"], password: "secret")
        XCTAssertEqual(short.status, 400)
        let uncounted = try await ask(setup, ["app": "Anything", "line": "2.0"], password: "secret")
        XCTAssertEqual(try version(uncounted), "2.0.1", "the password may number any app")
    }
}
