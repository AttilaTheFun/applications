import ApplicationsProtocol
import Foundation
import PipelineClient
import PipelineHTTP
import PipelineServer
import XCTest
@testable import ApplicationsServer

/// Releases: an app's builds on its platforms, each on its channel by how
/// it was published (a beta, or production from a release), its beta's
/// bundle id (`<id>.Beta`) one app with its production's.
final class ApplicationsTests: XCTestCase {
    private func makeServer() async throws -> (ApplicationsServer, URL) {
        let folder = TestIPA.folder()
        let paths = ServerPaths(root: folder.appendingPathComponent("support"))
        try paths.prepare()
        try ServerConfig(id: "test", name: "Test Mac", password: "secret").save(to: paths.config)
        let server = try ApplicationsServer(paths: paths, name: "Test Mac")
        try await server.prepareTLS(local: [LocalAddress(ip: "192.0.2.52", overlay: false)], hostName: "test-mac.local")
        return (server, folder)
    }

    private let password = ["authorization": "Bearer secret"]

    private func catalog(_ server: ApplicationsServer) async throws -> [AppRelease] {
        let answer = await server.handle(HTTPRequest(method: "GET", path: "/api/catalog", headers: password))
        XCTAssertEqual(answer.status, 200)
        return try WireCoding.decoder().decode([AppRelease].self, from: answer.data)
    }

    /// A package published from this computer, asking for a release or not.
    private func publish(_ server: ApplicationsServer, _ package: URL, release: Bool = false,
                         headers: [String: String] = [:]) async -> HTTPResponse {
        var headers = headers
        if release { headers["x-applications-release"] = "true" }
        return await server.handle(HTTPRequest(method: "POST", path: "/api/publish", headers: headers, bodyFile: package, local: true))
    }

    /// A release's build, as a release's CI has it published (TestRelease).
    private func release(_ server: ApplicationsServer, _ package: URL) async throws {
        let store = await server.builds
        try TestRelease.keep(package, in: store)
    }

    /// What schemes.json keeps.
    private func numbers(_ folder: URL) -> SchemeNumbers { SchemeNumbers.load(folder.appendingPathComponent("support/schemes.json")) }

    /// Published by hand, a build is a beta, whatever its bundle id (a CI
    /// that builds commits with the production id): no scheme, no number
    /// given, the package as it came.
    func testABuildPublishedByHandIsABetaWithNoScheme() async throws {
        let (server, folder) = try await makeServer()
        let ipa = try TestIPA.make(in: folder, bundleID: "com.example.Visor")
        let uploaded = try Data(contentsOf: ipa)
        let published = await publish(server, ipa)
        XCTAssertEqual(published.status, 201, String(decoding: published.data, as: UTF8.self))
        let build = try WireCoding.decoder().decode(Build.self, from: published.data)
        XCTAssertEqual(build.channel, .beta)
        XCTAssertNil(build.buildScheme)
        XCTAssertEqual(build.urlSchemes, ["testapp"])
        let kept = await server.builds.package(build.id)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(kept)), uploaded, "not signed again")
        XCTAssertEqual(numbers(folder), SchemeNumbers(), "no number given")
        let apps = try await catalog(server)
        let visor = try XCTUnwrap(apps.first { $0.app == "Visor" })
        XCTAssertEqual(visor.beta.map(\.id), [build.id])
        XCTAssertEqual(visor.production, [])
    }

    /// Asking for a release by hand (`X-Applications-Release: true`, what
    /// an earlier `publish --release` sent) is refused, saying where
    /// production comes from, for an iPhone's, a Mac's and a beta's bundle
    /// id alike, with the password or from this computer: nothing kept,
    /// no number given. The same builds published as betas are taken.
    func testAskingForAReleaseByHandIsRefused() async throws {
        let (server, folder) = try await makeServer()
        let packages = { [try TestIPA.make(in: folder, bundleID: "com.example.Visor"),
                          try TestMacApp.make(in: folder, bundleID: "com.example.VisorMac", version: "0.23"),
                          try TestIPA.make(in: folder, bundleID: "com.example.Visor.Beta", name: "Visor β")] }
        for package in try packages() {
            for headers in [[:], password] {
                let refused = await publish(server, package, release: true, headers: headers)
                XCTAssertEqual(refused.status, 403)
                let said = (try? JSONDecoder().decode([String: String].self, from: refused.data))?["error"] ?? ""
                XCTAssertEqual(said, "Refused: a build is production only when a release's CI publishes it, with its OIDC token (a v* tag "
                               + "released by a releaser: docs/CI.md); published by hand it is a beta, so publish it without asking for a release")
            }
        }
        let none = await server.builds.all()
        XCTAssertEqual(none, [])
        XCTAssertEqual(numbers(folder), SchemeNumbers())
        for package in try packages() {
            let beta = await publish(server, package, headers: ["x-applications-release": "false"])
            XCTAssertEqual(beta.status, 201, String(decoding: beta.data, as: UTF8.self))
            XCTAssertEqual(try WireCoding.decoder().decode(Build.self, from: beta.data).channel, .beta)
        }
    }

    /// The store takes nothing as production without the server's signer,
    /// which only a release's CI publish brings.
    func testTheStoreMakesNoProductionBuildByHand() throws {
        let folder = TestIPA.folder()
        let store = BuildStore(folder: folder.appendingPathComponent("builds"))
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let (file, metadata) = try store.unpack(try TestIPA.make(in: folder))
        XCTAssertThrowsError(try store.ready(file, metadata: metadata, channel: .production, commit: nil)) { error in
            XCTAssertTrue("\(error)".hasPrefix("a build is production only when a release's CI publishes it"), "\(error)")
        }
    }

    /// `<id>.Beta` and `<id>` are one app: listed under the production's
    /// name (the beta's without its mark, or as the server names either
    /// id), production's and the beta's builds each on its channel. Each
    /// bundle id is still apart where what is installed is told
    /// (`/api/apps`).
    func testABetaIsOneAppWithItsProduction() async throws {
        let (server, folder) = try await makeServer()
        try await release(server, try TestIPA.make(in: folder, bundleID: "com.example.Visor", version: "0.23.1", build: "1"))
        let published = await publish(server, try TestIPA.make(in: folder, bundleID: "com.example.Visor.Beta", name: "Visor β",
                                                               version: "0.23.2", build: "1"))
        XCTAssertEqual(published.status, 201, String(decoding: published.data, as: UTF8.self))
        var apps = try await catalog(server)
        XCTAssertEqual(apps.map(\.app), ["Visor"])
        XCTAssertEqual(apps[0].builds.map { "\($0.bundleID) \($0.channel?.rawValue ?? "")" },
                       ["com.example.Visor.Beta beta", "com.example.Visor production"])
        XCTAssertEqual(apps[0].production.map(\.version), ["0.23.1"])
        XCTAssertEqual(apps[0].beta.map(\.version), ["0.23.2"])
        let listed = await server.handle(HTTPRequest(method: "GET", path: "/api/apps", headers: password))
        XCTAssertEqual(try WireCoding.decoder().decode([AppBuilds].self, from: listed.data).map(\.bundleID),
                       ["com.example.Visor.Beta", "com.example.Visor"])

        // Named by the server, the production's id names the beta's too.
        await server.appNames.set("Visor Isomer", for: "com.example.Visor")
        apps = try await catalog(server)
        XCTAssertEqual(apps.map(\.app), ["Visor Isomer"])
        XCTAssertEqual(apps[0].builds.count, 2)
    }

    /// Applications from before builds had channels reads the catalog's
    /// `versions`, on the channels it knew: a beta's version is "alpha".
    func testTheCatalogStillHasVersionsForAnEarlierApplications() async throws {
        let (server, folder) = try await makeServer()
        try await release(server, try TestIPA.make(in: folder, version: "0.23.1", build: "1"))
        _ = await publish(server, try TestIPA.make(in: folder, version: "0.23.2", build: "1"))
        let answer = await server.handle(HTTPRequest(method: "GET", path: "/api/catalog", headers: password))
        let apps = try XCTUnwrap(try JSONSerialization.jsonObject(with: answer.data) as? [[String: Any]])
        let versions = try XCTUnwrap(apps.first?["versions"] as? [[String: Any]])
        XCTAssertEqual(versions.map { "\($0["version"] ?? "") \($0["channel"] ?? "")" }, ["0.23.2 alpha", "0.23.1 production"])
        XCTAssertEqual(versions.map { ($0["builds"] as? [Any])?.count }, [1, 1])
    }

    /// A branch's build (CI's :build:) goes with its pull request, a beta,
    /// not with main's, and only a pull request's newest three are kept.
    func testABranchsBuildIsItsPullRequestsNotMains() async throws {
        let (server, folder) = try await makeServer()
        let main = await server.handle(HTTPRequest(method: "POST", path: "/api/publish", headers: ["x-applications-app": Data("Visor".utf8).base64EncodedString()],
                                                   bodyFile: try TestIPA.make(in: folder, bundleID: "com.example.Visor"), local: true))
        XCTAssertEqual(main.status, 201)
        for build in 1...4 {
            let headers = ["x-applications-app": Data("Visor".utf8).base64EncodedString(), "x-applications-commit": "abc\(build)",
                           "x-applications-branch": Data("idea".utf8).base64EncodedString(), "x-applications-pull-request": "7"]
            let published = await server.handle(HTTPRequest(method: "POST", path: "/api/publish", headers: headers,
                                                            bodyFile: try TestIPA.make(in: folder, bundleID: "com.example.Visor", build: "\(build + 1)"),
                                                            local: true))
            XCTAssertEqual(published.status, 201, String(decoding: published.data, as: UTF8.self))
        }
        let apps = try await catalog(server)
        let visor = try XCTUnwrap(apps.first { $0.app == "Visor" })
        XCTAssertEqual(visor.builds.count, 1, "main's build alone in the app's")
        XCTAssertEqual(visor.pullRequests?.first?.builds.map(\.channel), [.beta, .beta, .beta])
        let pullRequest = try XCTUnwrap(visor.pullRequests?.first)
        XCTAssertEqual(pullRequest.number, 7)
        XCTAssertEqual(pullRequest.branch, "idea")
        XCTAssertEqual(pullRequest.builds.map { $0.origin?.commit }, ["abc4", "abc3", "abc2"], "its newest three")
    }

    /// A commit's build number is kept from when CI numbers it: asked again
    /// the same, the next commit one more, and said by the API before
    /// anything is built.
    func testACommitKeepsItsBuildNumber() async throws {
        let (server, folder) = try await makeServer()
        let published = await server.handle(HTTPRequest(method: "POST", path: "/api/publish",
                                                        headers: ["x-applications-app": Data("Visor".utf8).base64EncodedString()],
                                                        bodyFile: try TestIPA.make(in: folder, build: "4"), local: true))
        XCTAssertEqual(published.status, 201)
        let first = await server.nextBuildNumber(app: "Visor", version: "0.23", commit: "aaaa111")
        XCTAssertEqual(first, 5)
        let again = await server.nextBuildNumber(app: "Visor", version: "0.23", commit: "aaaa111")
        XCTAssertEqual(again, 5)
        let second = await server.nextBuildNumber(app: "Visor", version: "0.23", commit: "bbbb222")
        XCTAssertEqual(second, 6)
        let answer = await server.handle(HTTPRequest(method: "GET", path: "/api/build-number", query: ["commit": "aaaa111"], headers: password))
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(try WireCoding.decoder().decode([BuildNumber].self, from: answer.data).map(\.title), ["0.23 (5)"])
    }

    /// From 0.38 each build is a version of its own, MAJOR.MINOR.BUILD: the
    /// next is one past the line's highest, a commit keeps its version, and
    /// the API says it as the version alone.
    func testEachBuildIsAVersionOfItsLine() async throws {
        let (server, folder) = try await makeServer()
        let published = await server.handle(HTTPRequest(method: "POST", path: "/api/publish",
                                                        headers: ["x-applications-app": Data("Visor".utf8).base64EncodedString()],
                                                        bodyFile: try TestIPA.make(in: folder, version: "0.38.9", build: "1"), local: true))
        XCTAssertEqual(published.status, 201)
        let first = await server.nextVersion(app: "Visor", line: "0.38", commit: "cccc333")
        XCTAssertEqual(first, "0.38.10", "after 0.38.9, by number")
        let again = await server.nextVersion(app: "Visor", line: "0.38", commit: "cccc333")
        XCTAssertEqual(again, "0.38.10")
        let second = await server.nextVersion(app: "Visor", line: "0.38", commit: "dddd444")
        XCTAssertEqual(second, "0.38.11")
        let newLine = await server.nextVersion(app: "Visor", line: "0.39")
        XCTAssertEqual(newLine, "0.39.1", "a new line starts at 1")
        let answer = await server.handle(HTTPRequest(method: "GET", path: "/api/build-number", query: ["commit": "cccc333"], headers: password))
        XCTAssertEqual(try WireCoding.decoder().decode([BuildNumber].self, from: answer.data).map(\.title), ["0.38.10"])
        // Ordered by number: 0.38.10 after 0.38.9.
        XCTAssertTrue(ApplicationsServer.newer("0.38.10", "0.38.9"))
    }

    /// A retired app's builds are let go by its bundle id, and no other's.
    func testARetiredAppsBuildsAreLetGo() async throws {
        let (server, folder) = try await makeServer()
        for bundleID in ["com.example.Noso", "com.example.Noso", "com.example.Noson"] {
            let published = await server.handle(HTTPRequest(method: "POST", path: "/api/publish", headers: [:],
                                                            bodyFile: try TestIPA.make(in: folder, bundleID: bundleID), local: true))
            XCTAssertEqual(published.status, 201)
        }
        let store = BuildStore(folder: folder.appendingPathComponent("support/builds"))
        XCTAssertEqual(store.forget(bundleID: "com.example.Noso"), 2)
        XCTAssertEqual(store.all().map(\.bundleID), ["com.example.Noson"])
    }

    func testTheAPICanDoWithoutThePassword() async throws {
        let (server, _) = try await makeServer()
        let asked = await server.handle(HTTPRequest(method: "GET", path: "/api/catalog"))
        XCTAssertEqual(asked.status, 401)
        try await server.setRequirePassword(false)
        let open = await server.handle(HTTPRequest(method: "GET", path: "/api/catalog"))
        XCTAssertEqual(open.status, 200)
    }

    /// An app named by the server for a bundle id, or by an inbox upload's
    /// notes, groups a build whose own name says another.
    func testABuildsAppComesFromTheServersNamesOrTheNotesMarker() async throws {
        let (server, folder) = try await makeServer()
        await server.appNames.set("Visor Isomer", for: "com.example.Blue")
        let marked = "Fixes the details sheet.\n<!-- app: Blue Mac -->\n\n## What's new\n- Done"
        for (package, notes) in [(try TestIPA.make(in: folder, bundleID: "com.example.Blue", name: "Visor"), "First build."),
                                 (try TestMacApp.make(in: folder, bundleID: "com.example.BlueMac", name: "Visor", version: "0.23"), marked)] {
            let header = ["x-applications-notes": Data(notes.utf8).base64EncodedString()]
            let published = await server.handle(HTTPRequest(method: "POST", path: "/api/publish", headers: header, bodyFile: package, local: true))
            XCTAssertEqual(published.status, 201)
        }
        let apps = try await catalog(server)
        XCTAssertEqual(apps.first { $0.app == "Visor Isomer" }?.builds.map(\.platform), ["ios"])
        let mac = try XCTUnwrap(apps.first { $0.app == "Blue Mac" }?.builds.first)
        XCTAssertEqual(mac.notes, "Fixes the details sheet.\n\n## What's new\n- Done", "the marker is not part of the notes")
        XCTAssertNil(apps.first { $0.app == "Visor" })
    }
}
