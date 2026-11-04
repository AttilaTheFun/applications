import ApplicationsProtocol
import Foundation
import PipelineClient
import PipelineHTTP
import PipelineServer
import XCTest
@testable import ApplicationsServer

/// The build schemes Applications asks iOS about (BuildSchemes): named by
/// Applications' release and a number of that release's, given in order and
/// never again; 49 to other apps, then nothing more until Applications of a
/// newer release is published; stamped by CI before it builds, or added by
/// the server to a build that comes without one; production builds' alone,
/// a beta never numbered.
final class SchemeTests: XCTestCase {
    private func makeStore() throws -> (BuildStore, URL) {
        let folder = TestIPA.folder()
        let store = BuildStore(folder: folder.appendingPathComponent("builds"))
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        return (store, folder)
    }

    /// What schemes.json keeps.
    private func numbers(_ folder: URL) -> SchemeNumbers { SchemeNumbers.load(folder.appendingPathComponent("schemes.json")) }

    /// Applications' iPhone build of a version, published by its release.
    private func publishApplications(_ version: String, to store: BuildStore, in folder: URL, at time: TimeInterval) throws {
        try TestRelease.keep(try TestIPA.make(in: folder, bundleID: BuildSchemes.applicationsBundleID, name: "Applications",
                                              version: version, build: "1"),
                             in: store, now: Date(timeIntervalSince1970: time))
    }

    /// A commit for each of many apps, none the start of another.
    private func commit(_ number: Int) -> String { String(format: "c%06d", number) }

    func testASchemeNamesItsReleaseAndNumber() {
        XCTAssertEqual(BuildSchemes.scheme(release: "0.6", number: 3), "applications-0.6-build-3")
        let parsed = BuildSchemes.parse("applications-0.12-build-49")
        XCTAssertEqual(parsed?.release, "0.12")
        XCTAssertEqual(parsed?.number, 49)
        for other in ["releases-build-3", "applications", "testapp", "applications-0.6-build-0", "applications-0.6-build-51",
                      "applications-0.6-build-03", "applications-0.6.3-build-1", "applications-x.6-build-1", "applications-0.6-build-"] {
            XCTAssertNil(BuildSchemes.parse(other), other)
        }
        XCTAssertNil(BuildSchemes.parse(nil))
        XCTAssertEqual(BuildSchemes.release(of: "0.6.3"), "0.6")
        XCTAssertEqual(BuildSchemes.release(of: "0.6"), "0.6", "a release already")
        XCTAssertEqual(BuildSchemes.release(of: "1.10.200"), "1.10")
        XCTAssertNil(BuildSchemes.release(of: "1"))
        XCTAssertNil(BuildSchemes.release(of: "0.6b"))
        XCTAssertNil(BuildSchemes.release(of: ""))
        let all = BuildSchemes.all(release: "0.6")
        XCTAssertEqual(all.count, 50)
        XCTAssertEqual(all.first, "applications-0.6-build-1")
        XCTAssertEqual(all.last, "applications-0.6-build-50")
        XCTAssertEqual(BuildSchemes.othersLimit, 49)
    }

    /// Applications lists the apps' own link schemes (`visor`), by which iOS
    /// says whether each is installed: no build's scheme, and within iOS's
    /// 50.
    func testTheAppListsTheAppsOwnSchemes() throws {
        let info = try appInfo("Info.ios.plist")
        let schemes = try XCTUnwrap(info["LSApplicationQueriesSchemes"] as? [String])
        XCTAssertTrue(schemes.contains("visor"))
        XCTAssertLessThanOrEqual(schemes.count, 50)
        XCTAssertEqual(schemes.filter { BuildSchemes.parse($0) != nil || $0.hasPrefix("releases-build-") }, [], "no build's own scheme")
        XCTAssertEqual(Set(schemes).count, schemes.count)
    }

    /// Applications and its server have one version, as Visor's app and
    /// server do: the server's own release, its schemes before the first
    /// Applications build is published, is then the app's.
    func testTheAppsAndTheServerShareOneVersion() throws {
        for name in ["Info.ios.plist", "Info.mac.plist"] {
            let info = try appInfo(name)
            XCTAssertEqual(info["CFBundleShortVersionString"] as? String, ApplicationsServer.version,
                           "app/\(name)'s version is the server's (ApplicationsServer.version), and MODULE.bazel's")
        }
    }

    /// Numbers go out in order under the current release, one per app's
    /// commit, each kept with whom it went to.
    func testNumbersAreGivenInOrder() throws {
        let (store, folder) = try makeStore()
        try publishApplications("0.6.2", to: store, in: folder, at: 1)
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Visor", commit: "aaaa111").scheme, "applications-0.6-build-1")
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Noson", commit: "bbbb222").scheme, "applications-0.6-build-2")
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Visor", commit: "cccc333"),
                       BuildSchemeAnswer(release: "0.6", scheme: "applications-0.6-build-3"))
        let kept = numbers(folder)
        XCTAssertEqual(kept.applications, "0.6")
        XCTAssertEqual(kept.releases["0.6"]?.next, 4)
        XCTAssertEqual(kept.releases["0.6"]?.given, [SchemeNumbers.Given(number: 1, bundleID: "com.example.Visor", commit: "aaaa111"),
                                                      SchemeNumbers.Given(number: 2, bundleID: "com.example.Noson", commit: "bbbb222"),
                                                      SchemeNumbers.Given(number: 3, bundleID: "com.example.Visor", commit: "cccc333")])
    }

    /// Asked again for an app's commit, the same scheme (by its whole sha
    /// or the start of it); another app's build of that commit gets its own.
    func testTheSameAppAndCommitGetTheSameScheme() throws {
        let (store, folder) = try makeStore()
        try publishApplications("0.6.2", to: store, in: folder, at: 1)
        let sha = "4f1c2a9e0b7d3c5a8e6f1b2d4c9a7e3f5b8d0c1a"
        let first = try store.scheme(bundleID: "com.example.Visor", commit: sha)
        XCTAssertEqual(first.scheme, "applications-0.6-build-1")
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Visor", commit: sha), first)
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Visor", commit: String(sha.prefix(7))), first)
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Noson", commit: sha).scheme, "applications-0.6-build-2")
        XCTAssertEqual(numbers(folder).releases["0.6"]?.next, 3)
    }

    /// Once 49 are given, other apps' builds are refused, saying what to
    /// do; a commit given one keeps it, and Applications is still answered
    /// and published. 50 is never given.
    func testAfterFortyNineOnlyApplicationsIsAccepted() throws {
        let (store, folder) = try makeStore()
        try publishApplications("0.6.2", to: store, in: folder, at: 1)
        for number in 1...49 {
            XCTAssertEqual(try store.scheme(bundleID: "com.example.App\(number)", commit: commit(number)).scheme,
                           "applications-0.6-build-\(number)")
        }
        XCTAssertThrowsError(try store.scheme(bundleID: "com.example.Visor", commit: "dddd444")) { error in
            XCTAssertEqual("\(error)", "All 49 build schemes of Applications 0.6 are given out: publish an Applications build of a newer "
                           + "release (its version's MAJOR.MINOR past 0.6) to start that release's")
        }
        XCTAssertEqual(try store.scheme(bundleID: "com.example.App7", commit: commit(7)).scheme, "applications-0.6-build-7")
        XCTAssertEqual(try store.scheme(bundleID: BuildSchemes.applicationsBundleID, commit: "eeee555"),
                       BuildSchemeAnswer(release: "0.6", scheme: nil))
        // A release's build that comes without a scheme is refused the same
        // way; a beta, which needs none, is taken.
        XCTAssertThrowsError(try TestRelease.keep(try TestIPA.make(in: folder), in: store, now: Date(timeIntervalSince1970: 2))) { error in
            XCTAssertTrue("\(error)".contains("publish an Applications build of a newer release"), "\(error)")
        }
        XCTAssertNoThrow(try publishApplications("0.6.3", to: store, in: folder, at: 3))
        XCTAssertEqual(numbers(folder).releases["0.6"]?.next, 50)
        XCTAssertEqual(store.apps(platform: "ios").map(\.bundleID), [BuildSchemes.applicationsBundleID])
        XCTAssertNil(try store.add(package: try TestIPA.make(in: folder), notes: "", now: Date(timeIntervalSince1970: 4)).buildScheme)
    }

    /// Applications of a newer release, once published, starts that
    /// release's numbers at 1, a commit numbered under the last one
    /// included; an older release's build published after it (a branch's)
    /// does not take it back, nor does Applications' builds going; 0.10
    /// is newer than 0.9.
    func testANewerApplicationsStartsItsReleasesNumbers() throws {
        let (store, folder) = try makeStore()
        try publishApplications("0.6.2", to: store, in: folder, at: 1)
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Visor", commit: "aaaa111").scheme, "applications-0.6-build-1")
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Noson", commit: "bbbb222").scheme, "applications-0.6-build-2")
        try publishApplications("0.7.1", to: store, in: folder, at: 2)
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Visor", commit: "cccc333").scheme, "applications-0.7-build-1")
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Visor", commit: "aaaa111").scheme, "applications-0.7-build-2")
        try publishApplications("0.6.4", to: store, in: folder, at: 3)
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Noson", commit: "dddd444").scheme, "applications-0.7-build-3")
        XCTAssertEqual(store.forget(bundleID: BuildSchemes.applicationsBundleID), 3)
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Noson", commit: "eeee555").scheme, "applications-0.7-build-4",
                       "kept in schemes.json")
        XCTAssertEqual(numbers(folder).releases["0.6"]?.next, 3, "0.6's numbers kept, and never given again")
        try publishApplications("0.9.1", to: store, in: folder, at: 4)
        try publishApplications("0.10.1", to: store, in: folder, at: 5)
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Visor", commit: "ffff666").scheme, "applications-0.10-build-1")
    }

    /// Before any Applications is published, the server's own release; then
    /// Applications', whatever it is. Asking for Applications gives no number.
    func testTheServersOwnReleaseUntilApplicationsIsPublished() throws {
        let (store, folder) = try makeStore()
        let own = try XCTUnwrap(BuildSchemes.release(of: ApplicationsServer.version))
        XCTAssertEqual(BuildStore.ownRelease, own)
        XCTAssertEqual(try store.scheme(bundleID: BuildSchemes.applicationsBundleID, commit: "aaaa111"),
                       BuildSchemeAnswer(release: own, scheme: nil))
        XCTAssertEqual(numbers(folder), SchemeNumbers(), "Applications takes no number")
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Visor", commit: "bbbb222").scheme, "applications-\(own)-build-1")
        try publishApplications("0.5.7", to: store, in: folder, at: 1)
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Visor", commit: "cccc333").scheme, "applications-0.5-build-1")
    }

    /// A release's build CI stamped keeps its scheme as it is signed, and
    /// takes no number; one stamped with a scheme not given to it here is
    /// published with it all the same (the log says so).
    func testAStampedBuildKeepsItsSchemeAndTakesNoNumber() throws {
        let (store, folder) = try makeStore()
        try publishApplications("0.6.2", to: store, in: folder, at: 1)
        let scheme = try XCTUnwrap(try store.scheme(bundleID: "com.example.Visor", commit: "aaaa111").scheme)
        let build = try TestRelease.keep(try TestIPA.make(in: folder, stamped: scheme), in: store, commit: "aaaa111",
                                         now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(build.buildScheme, scheme)
        XCTAssertEqual(build.urlSchemes, ["testapp", scheme])
        let stray = try TestRelease.keep(try TestIPA.make(in: folder, bundleID: "com.example.Noson", name: "Noson",
                                                          stamped: "applications-0.6-build-7"),
                                         in: store, now: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(stray.buildScheme, "applications-0.6-build-7")
        XCTAssertEqual(numbers(folder).releases["0.6"]?.next, 2)
    }

    /// A release's build that comes without a scheme (a CI that does not
    /// stamp) is given the next number, its scheme added as the server
    /// signs it; its commit keeps the number.
    func testABuildWithoutASchemeIsGivenOneAsItIsSigned() throws {
        let (store, folder) = try makeStore()
        try publishApplications("0.6.2", to: store, in: folder, at: 1)
        let build = try TestRelease.keep(try TestIPA.make(in: folder), in: store, commit: "aaaa111", now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(build.buildScheme, "applications-0.6-build-1")
        let package = try XCTUnwrap(store.package(build.id))
        XCTAssertEqual(try IPAMetadata.read(package).urlSchemes, ["testapp", "applications-0.6-build-1"])
        XCTAssertNoThrow(try PackageCheck.verify(package: package, platform: "ios"))
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Visor", commit: "aaaa111").scheme, "applications-0.6-build-1")
        let uncommitted = try TestRelease.keep(try TestIPA.make(in: folder, build: "24"), in: store, now: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(uncommitted.buildScheme, "applications-0.6-build-2")
        XCTAssertEqual(numbers(folder).releases["0.6"]?.given.last, SchemeNumbers.Given(number: 2, bundleID: "com.example.Visor", commit: nil))
    }

    /// A beta is never numbered, whatever its bundle id: published as it
    /// came, with no scheme (one CI stamped in anyway is not asked about),
    /// and a beta's bundle id is answered with none. Applications' betas
    /// set no release, its production id's published as a beta neither.
    func testABetaIsNeverNumbered() throws {
        let (store, folder) = try makeStore()
        try publishApplications("0.6.2", to: store, in: folder, at: 1)
        let ipa = try TestIPA.make(in: folder)
        let uploaded = try Data(contentsOf: ipa)
        let beta = try store.add(package: ipa, notes: "", origin: BuildOrigin(commit: "aaaa111"), now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(beta.channel, .beta)
        XCTAssertNil(beta.buildScheme)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.package(beta.id))), uploaded, "not signed again")
        let stamped = try store.add(package: try TestIPA.make(in: folder, stamped: "applications-0.6-build-3"), notes: "",
                                    now: Date(timeIntervalSince1970: 3))
        XCTAssertNil(stamped.buildScheme)
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Visor.Beta", commit: "bbbb222"), BuildSchemeAnswer(release: "0.6", scheme: nil))
        XCTAssertEqual(numbers(folder).releases["0.6"], nil, "no number given")
        _ = try store.add(package: try TestIPA.make(in: folder, bundleID: BuildSchemes.applicationsBundleID + ".Beta", name: "Applications β",
                                                    version: "0.7.1", build: "1"), notes: "", now: Date(timeIntervalSince1970: 4))
        _ = try store.add(package: try TestIPA.make(in: folder, bundleID: BuildSchemes.applicationsBundleID, name: "Applications",
                                                    version: "0.8.1", build: "1"), notes: "", now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(numbers(folder).applications, "0.6")
        XCTAssertEqual(try store.scheme(bundleID: "com.example.Visor", commit: "cccc333").scheme, "applications-0.6-build-1")
    }

    /// A number given for a build that then could not be signed again goes
    /// back, unless another was given after it.
    func testANumberNoBuildCarriesIsGivenBack() {
        var numbers = SchemeNumbers()
        let first = numbers.reserve(release: "0.6", bundleID: "com.example.Visor", commit: nil)
        let second = numbers.reserve(release: "0.6", bundleID: "com.example.Noson", commit: nil)
        XCTAssertEqual(first?.number, 1)
        XCTAssertEqual(second?.number, 2)
        numbers.giveBack(release: "0.6", number: 1)
        XCTAssertEqual(numbers.releases["0.6"]?.next, 3, "2 came after it")
        numbers.giveBack(release: "0.6", number: 2)
        XCTAssertEqual(numbers.releases["0.6"]?.next, 2)
        XCTAssertEqual(numbers.releases["0.6"]?.given.map(\.number), [1])
    }

    /// CI elsewhere asks over HTTPS, with the password, or from this
    /// computer without it, as publishing is; answered for Applications
    /// and a beta with no scheme; refused, saying why, once the release's
    /// are given.
    func testTheAPIGivesSchemesAsPublishingIsAllowed() async throws {
        let folder = TestIPA.folder()
        let paths = ServerPaths(root: folder.appendingPathComponent("support"))
        try paths.prepare()
        try ServerConfig(id: "test", name: "Test Mac", password: "secret").save(to: paths.config)
        let server = try ApplicationsServer(paths: paths, name: "Test Mac")
        func ask(_ bundleID: String, _ commit: String, headers: [String: String] = ["authorization": "Bearer secret"],
                 local: Bool = false) async throws -> HTTPResponse {
            let body = try WireCoding.encoder().encode(BuildSchemeRequest(bundleID: bundleID, commit: commit))
            return await server.handle(HTTPRequest(method: "POST", path: "/api/build-scheme", headers: headers, body: body, local: local))
        }
        let own = BuildStore.ownRelease
        let answer = try await ask("com.example.Visor", "aaaa111")
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(String(decoding: answer.data, as: UTF8.self), #"{"release":"\#(own)","scheme":"applications-\#(own)-build-1"}"#)
        let fromHere = try await ask("com.example.Visor", "aaaa111", headers: [:], local: true)
        XCTAssertEqual(fromHere.status, 200)
        XCTAssertEqual(try WireCoding.decoder().decode(BuildSchemeAnswer.self, from: fromHere.data).scheme, "applications-\(own)-build-1")
        let elsewhere = try await ask("com.example.Visor", "aaaa111", headers: [:])
        XCTAssertEqual(elsewhere.status, 401)
        let short = try await ask("com.example.Visor", "abc")
        XCTAssertEqual(short.status, 400)
        let applications = try await ask(BuildSchemes.applicationsBundleID, "aaaa111")
        XCTAssertEqual(String(decoding: applications.data, as: UTF8.self), #"{"release":"\#(own)"}"#)
        let beta = try await ask("com.example.Visor.Beta", "aaaa111")
        XCTAssertEqual(String(decoding: beta.data, as: UTF8.self), #"{"release":"\#(own)"}"#)
        for number in 2...49 { _ = try await ask("com.example.App\(number)", commit(number)) }
        let usedUp = try await ask("com.example.Noson", "bbbb222")
        XCTAssertEqual(usedUp.status, 409)
        XCTAssertTrue(String(decoding: usedUp.data, as: UTF8.self).contains("publish an Applications build of a newer release"))
    }

    /// One of the apps' Info.plists (app/), from the test bundle's Resources
    /// (macos_unit_test's `resources`), wherever the bundle runs: by
    /// `bazel test` on a Mac, or alone on a Mac slot (`oss machine xctest`).
    private func appInfo(_ name: String) throws -> [String: Any] {
        let base = (name as NSString).deletingPathExtension
        let plist = try XCTUnwrap(Bundle(for: SchemeTests.self).url(forResource: base, withExtension: "plist"), "\(name) in the test bundle's Resources")
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
    }
}
