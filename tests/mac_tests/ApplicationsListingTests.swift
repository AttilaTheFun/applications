import ApplicationsProtocol
import XCTest

/// An app's beta (`<id>.Beta`) and its production are one row, its
/// production's builds and its betas apart, production's first; each bundle
/// id stays its own, by which what is installed is told apart. The row shows
/// the app's latest Alpha (its newest build that isn't production), else
/// its production (2026-11-01).
@MainActor
final class ApplicationsListingTests: XCTestCase {
    func testABetaIsOneRowWithItsProduction() throws {
        let store = ApplicationsStore()
        store.showFixture()
        let visor = try XCTUnwrap(store.listing(bundleID: "com.example.Visor"))
        XCTAssertEqual(store.listing(bundleID: "com.example.Visor.Beta")?.id, visor.id, "the beta's id finds its production's row")
        XCTAssertEqual(store.listings.filter { $0.name == "Visor" }.count, 1)
        XCTAssertEqual(visor.production?.bundleID, "com.example.Visor")
        XCTAssertEqual(visor.production?.builds.map(\.buildNumber), ["12"])
        XCTAssertEqual(visor.betas.map(\.bundleID), ["com.example.Visor.Beta"])
        XCTAssertEqual(visor.betas.first?.builds.map(\.buildNumber), ["7", "6"])
        XCTAssertEqual(visor.groups.map(\.bundleID), ["com.example.Visor", "com.example.Visor.Beta"], "production's first")
        XCTAssertEqual(visor.shown?.bundleID, "com.example.Visor.Beta")
        XCTAssertEqual(visor.versionTitle, "0.35 (7)", "the latest Alpha's numbers, though there is a production")
        XCTAssertTrue(visor.showsBeta)
        // Its page: the latest of each variant there is (no Beta here), then
        // every build, in version order.
        let all = AppBuildsView.everyBuild(visor.groups)
        XCTAssertEqual(all.map(\.build.buildNumber), ["7", "6", "12"])
        XCTAssertEqual(AppBuildsView.latestOfEachVariant(all).map(\.build.buildNumber), ["7", "12"])
        XCTAssertEqual(AppBuildsView.latestOfEachVariant(all).map { BuildVariants.variant(of: $0.build) }, ["Alpha", "Production"])
        // A beta alone: the row shows it, named as its production, marked
        // as a beta's.
        let noson = try XCTUnwrap(store.listing(bundleID: "com.example.Noson"))
        XCTAssertNil(noson.production)
        XCTAssertEqual(noson.name, "Noson")
        XCTAssertEqual(noson.shown?.bundleID, "com.example.Noson.Beta")
        XCTAssertTrue(noson.showsBeta)
        // Production alone: its own row, no betas.
        let halo = try XCTUnwrap(store.listing(bundleID: "com.example.Halo"))
        XCTAssertEqual(halo.production?.bundleID, "com.example.Halo")
        XCTAssertEqual(halo.betas.count, 0)
        XCTAssertFalse(halo.showsBeta)
        XCTAssertEqual(store.listings.map(\.id), ["com.example.Halo", "com.example.Noson", "com.example.Visor"], "one row an app")
    }

    /// A build's variant is its BuildVariant, else Production for a
    /// production build and Alpha for any other; builds go in version order
    /// by number (0.10.10 after 0.10.9), and an app's page has the latest
    /// of each variant there is, Alpha, Beta, Production, a newer Beta not
    /// hiding the latest Alpha. An AdHoc build (a pull request's, by hand)
    /// is among every build but not the latest's, and the row never shows
    /// it while the app has another.
    func testVariantsAndVersionOrder() {
        let now = Date()
        func build(_ id: String, _ version: String, _ channel: ReleaseChannel, _ variant: String?, _ ago: TimeInterval) -> Build {
            Build(id: id, bundleID: "com.example.Notes", name: "Notes", version: version, buildNumber: "1", platform: DeviceInstalls.platform,
                  published: now.addingTimeInterval(-ago), size: 0, channel: channel, buildVariant: variant)
        }
        let builds = [build("a", "0.10.9", .beta, "Alpha", 300), build("b", "0.10.10", .beta, "Beta", 0),
                      build("c", "0.10.10", .beta, "Alpha", 60), build("p", "0.10.8", .production, "Production", 600),
                      build("old", "0.10.7", .beta, nil, 900), build("oldp", "0.10.6", .production, nil, 1200),
                      build("x", "0.10.11", .beta, "AdHoc", -60)]
        XCTAssertEqual(builds.map(BuildVariants.variant(of:)), ["Alpha", "Beta", "Alpha", "Production", "Alpha", "Production", "AdHoc"])
        let rows = AppListing.rows(AppRelease(app: "Notes", iconBuild: nil, builds: builds), builds: builds)
        let all = AppBuildsView.everyBuild(rows.first?.groups ?? [])
        XCTAssertEqual(all.map(\.build.id), ["x", "b", "c", "a", "p", "old", "oldp"], "by version, then the newer first")
        XCTAssertEqual(AppBuildsView.latestOfEachVariant(all).map(\.build.id), ["c", "b", "p"], "no AdHoc among the latest")
        XCTAssertEqual(rows.first?.shown?.latest?.id, "c", "the row: the latest Alpha, not the newer AdHoc or Beta")
        XCTAssertEqual(rows.first?.versionTitle, "0.10.10")
        XCTAssertEqual(rows.first?.showsBeta, true)
    }

    /// A beta published with the production's id (a CI that builds commits
    /// with it) is with the betas, under that id, not production's.
    func testABetaOfTheProductionIDIsABeta() {
        let now = Date()
        func build(_ id: String, _ bundleID: String, _ channel: ReleaseChannel, _ ago: TimeInterval) -> Build {
            Build(id: id, bundleID: bundleID, name: "Visor", version: "0.41.\(id)", buildNumber: "1", platform: DeviceInstalls.platform,
                  published: now.addingTimeInterval(-ago), size: 0, channel: channel)
        }
        let app = AppRelease(app: "Visor", iconBuild: nil, builds: [build("3", "com.example.Visor", .beta, 0),
                                                                    build("2", "com.example.Visor.Beta", .beta, 60),
                                                                    build("1", "com.example.Visor", .production, 120)])
        let rows = AppListing.rows(app, builds: app.builds)
        XCTAssertEqual(rows.map(\.id), ["com.example.Visor"])
        XCTAssertEqual(rows.first?.production?.builds.map(\.id), ["1"])
        XCTAssertEqual(rows.first?.betas.map(\.bundleID), ["com.example.Visor", "com.example.Visor.Beta"])
        XCTAssertEqual(rows.first?.betas.map { $0.builds.map(\.id) }, [["3"], ["2"]])
    }

    /// An app's iPhone and Mac ids, as an app with both has them: on each device
    /// its own production and beta are one row, a Mac's `<id>.Mac.Beta`
    /// with `<id>.Mac` (the `.Mac` kept), an iPhone's `<id>.Beta` with
    /// `<id>`; the other device's builds are not among them.
    func testEachDevicesBetaIsWithItsOwnProduction() {
        let now = Date()
        func build(_ id: String, _ bundleID: String, _ platform: String, _ channel: ReleaseChannel, _ ago: TimeInterval) -> Build {
            Build(id: id, bundleID: bundleID, name: BundleVariant.isBeta(bundleID) ? "Notes β" : "Notes", version: "0.9.\(id)",
                  buildNumber: "1", platform: platform, published: now.addingTimeInterval(-ago), size: 0, channel: channel)
        }
        let app = AppRelease(app: "Notes", iconBuild: nil, builds: [
            build("4", "com.example.Notes.Mac.Beta", "macos", .beta, 0),
            build("3", "com.example.Notes.Beta", "ios", .beta, 30),
            build("2", "com.example.Notes.Mac", "macos", .production, 60),
            build("1", "com.example.Notes", "ios", .production, 90),
        ])
        let mac = AppListing.rows(app, builds: app.builds(on: "macos"))
        XCTAssertEqual(mac.map(\.id), ["com.example.Notes.Mac"])
        XCTAssertEqual(mac.first?.name, "Notes")
        XCTAssertEqual(mac.first?.production?.builds.map(\.id), ["2"])
        XCTAssertEqual(mac.first?.betas.map(\.bundleID), ["com.example.Notes.Mac.Beta"])
        XCTAssertEqual(mac.first?.versionTitle, "0.9.4", "the beta's: the latest Alpha")
        let phone = AppListing.rows(app, builds: app.builds(on: "ios"))
        XCTAssertEqual(phone.map(\.id), ["com.example.Notes"])
        XCTAssertEqual(phone.first?.production?.builds.map(\.id), ["1"])
        XCTAssertEqual(phone.first?.betas.map(\.bundleID), ["com.example.Notes.Beta"])
        // Betas alone on a Mac: the row is the production's id and name.
        let betas = AppListing.rows(app, builds: app.builds(on: "macos").filter { $0.channel == .beta })
        XCTAssertEqual(betas.map(\.id), ["com.example.Notes.Mac"])
        XCTAssertEqual(betas.first?.name, "Notes")
        XCTAssertEqual(betas.first?.showsBeta, true)
    }

    /// An id with no `.Beta` beside it (Visor Server, beside Visor on a
    /// Mac, counted under Visor) is a row of its own, under its own name;
    /// so is one that ends in "Beta" without the dot.
    func testAnIDWithNoBetaIsARowOfItsOwn() {
        let now = Date()
        func build(_ id: String, _ bundleID: String, _ name: String, _ channel: ReleaseChannel, _ ago: TimeInterval) -> Build {
            Build(id: id, bundleID: bundleID, name: name, version: "0.41.\(id)", buildNumber: "1", platform: "macos",
                  published: now.addingTimeInterval(-ago), size: 0, channel: channel)
        }
        let app = AppRelease(app: "Visor", iconBuild: nil, builds: [
            build("4", "com.example.Visor.Mac.Beta", "Visor β", .beta, 0),
            build("3", "com.example.VisorServer", "Visor Server", .production, 30),
            build("2", "com.example.VisorBeta", "Visor Beta", .beta, 60),
            build("1", "com.example.Visor.Mac", "Visor", .production, 90),
        ])
        let rows = AppListing.rows(app, builds: app.builds)
        XCTAssertEqual(rows.map(\.id), ["com.example.Visor.Mac", "com.example.VisorServer", "com.example.VisorBeta"])
        XCTAssertEqual(rows.map(\.name), ["Visor", "Visor Server", "Visor Beta"])
        XCTAssertEqual(rows[1].production?.builds.map(\.id), ["3"])
        XCTAssertEqual(rows[1].betas.count, 0)
        XCTAssertNil(rows[2].production)
        XCTAssertEqual(rows[2].betas.map(\.bundleID), ["com.example.VisorBeta"])
    }

    /// An app that moved to another bundle id (Visor's iPhone app, from
    /// its own id to one bundle id an app) is one row, under the id of its
    /// newest build; the earlier id's row goes.
    func testAnAppThatMovedBundleIDsIsOneRow() {
        let now = Date()
        func build(_ id: String, _ bundleID: String, _ ago: TimeInterval) -> Build {
            Build(id: id, bundleID: bundleID, name: "Visor", version: "0.43.\(id)", buildNumber: "1", platform: DeviceInstalls.platform,
                  published: now.addingTimeInterval(-ago), size: 0, channel: .beta, buildVariant: "Alpha")
        }
        let app = AppRelease(app: "Visor", iconBuild: nil, builds: [build("130", "com.example.Visor", 0),
                                                                    build("114", "com.example.VisorClient.iOS", 600),
                                                                    build("113", "com.example.VisorClient.iOS", 900)])
        let rows = AppListing.rows(app, builds: app.builds)
        XCTAssertEqual(rows.map(\.id), ["com.example.Visor"])
        XCTAssertEqual(rows.first?.versionTitle, "0.43.130")
    }

    /// A build's link (`applications://build?…`) and its notification open
    /// the app's one entry, its production's, at the build: a beta's too.
    func testABuildsLinkOpensItsAppsEntry() async throws {
        let store = ApplicationsStore()
        store.showFixture()
        func opened(_ link: String) async throws -> (String?, [ApplicationsRoute]) {
            store.selection = nil
            store.path = []
            store.open(link: try XCTUnwrap(URL(string: link)))
            for _ in 0..<200 where store.selection == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            return (store.selection, store.path)
        }
        let scheme = ApplicationsStore.linkScheme
        var (selection, path) = try await opened("\(scheme)://build?id=visor-7")
        XCTAssertEqual(selection, "com.example.Visor", "a beta's build: its production's entry")
        XCTAssertEqual(path, [.build("visor-7")])
        (selection, path) = try await opened("\(scheme)://build?commit=34a5f7c&app=Visor")
        XCTAssertEqual(selection, "com.example.Visor")
        XCTAssertEqual(path, [.build("visor-34")])
        (selection, path) = try await opened("\(scheme)://build?id=noson-9")
        XCTAssertEqual(selection, "com.example.Noson", "a beta alone: its production's id all the same")
        XCTAssertEqual(path, [.build("noson-9")])
        store.selection = nil
        store.open(build: "visor-6", installing: false)
        for _ in 0..<200 where store.selection == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.selection, "com.example.Visor")
        XCTAssertEqual(store.path, [.build("visor-6")])
    }
}
