import ApplicationsProtocol
import PipelineSnapshots
import SwiftUI
import XCTest
@testable import ApplicationsApp

/// Applications' screens on its fixture, on a phone and an iPad: their titles
/// as Visor has them (the list titled only in one column; beside it the
/// detail titled "Applications" with nothing open, then the app's name), a
/// sheet within a phone's width, and each screen as its kept picture.
@MainActor
final class ApplicationsScreensTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)
    private let pad = CGSize(width: 1180, height: 820)
    private var bundle: Bundle { Bundle(for: ApplicationsScreensTests.self) }

    private func store() -> ApplicationsStore {
        let store = ApplicationsStore()
        store.showFixture()
        return store
    }

    /// The list has one row an app, its production's name, showing its
    /// latest Alpha (its newest build that isn't production), marked so,
    /// else its production: Visor's beta and production one row, showing
    /// the beta; Noson's beta alone; Halo's production alone.
    func testThePhonesListIsTitled() {
        let store = store()
        let host = SnapshotHost(RootView().environment(store), size: phone, regular: false)
        XCTAssertEqual(host.shownTitle(), "Applications")
        XCTAssertEqual(store.listings.map(\.id), ["com.example.Halo", "com.example.Noson", "com.example.Visor"])
        XCTAssertEqual(store.listings.map(\.name), ["Halo", "Noson", "Visor"])
        XCTAssertEqual(store.listings.map(\.showsBeta), [false, true, true])
        Snapshot.check(host.picture(), named: "phone-list", kept: SnapshotHost.kept("phone-list", in: bundle))
        host.close()
    }

    /// Settings on a phone is the screen's width (it asked for a Mac
    /// window's least width, and ran off the right edge).
    func testSettingsFitsAPhone() {
        let host = SnapshotHost(SettingsView().environment(store()), size: phone, regular: false)
        XCTAssertLessThanOrEqual(host.listOverflow(), 0.5)
        Snapshot.check(host.picture(), named: "phone-settings", kept: SnapshotHost.kept("phone-settings", in: bundle))
        host.close()
    }

    /// An app's page has the latest of each variant there is (Alpha, Beta,
    /// Production), then every build in version order; a version's page has
    /// every build of it.
    func testAVersionsPageHasEveryBuild() throws {
        let store = store()
        store.selection = "com.example.Visor"
        let host = SnapshotHost(RootView().environment(store), size: phone, regular: false)
        let listing = try XCTUnwrap(store.listing(bundleID: "com.example.Visor"))
        let all = AppBuildsView.everyBuild(listing.groups)
        XCTAssertEqual(AppBuildsView.latestOfEachVariant(all).map(\.build.buildNumber), ["7", "12"])
        XCTAssertEqual(all.map(\.build.buildNumber), ["7", "6", "12"])
        Snapshot.check(host.picture(), named: "phone-app", kept: SnapshotHost.kept("phone-app", in: bundle))
        store.path = [.version("Visor", "0.35")]
        host.settle()
        XCTAssertEqual(store.versionBuilds(app: "Visor", version: "0.35").flatMap(\.builds).map(\.buildNumber), ["7", "6"])
        Snapshot.check(host.picture(), named: "phone-version", kept: SnapshotHost.kept("phone-version", in: bundle))
        host.close()
    }

    /// An app with no production build yet: its page has its betas alone,
    /// under its production's name, reached by its beta's id too.
    func testABetaAlonesPageHasItsBetas() throws {
        let store = store()
        store.selection = try XCTUnwrap(store.listing(bundleID: "com.example.Noson.Beta")?.id)
        XCTAssertEqual(store.selection, "com.example.Noson")
        let host = SnapshotHost(RootView().environment(store), size: phone, regular: false)
        let listing = try XCTUnwrap(store.listing(bundleID: "com.example.Noson"))
        XCTAssertNil(listing.production)
        XCTAssertEqual(listing.betas.map(\.bundleID), ["com.example.Noson.Beta"])
        XCTAssertEqual(listing.name, "Noson")
        Snapshot.check(host.picture(), named: "phone-app-betas", kept: SnapshotHost.kept("phone-app-betas", in: bundle))
        host.close()
    }

    /// An app is asked about by its own link scheme, one its builds declare
    /// and Applications lists: not a build's own, nor one iOS won't answer.
    func testAnAppIsAskedAboutByItsOwnScheme() {
        func app(_ schemes: [String]) -> AppBuilds {
            AppBuilds(bundleID: "com.example.Visor", name: "Visor", builds: [
                Build(id: "1", bundleID: "com.example.Visor", name: "Visor", version: "0.43.1", buildNumber: "1", published: Date(), size: 0,
                      urlSchemes: schemes),
            ])
        }
        let queried: Set<String> = ["visor", "halo"]
        XCTAssertEqual(DeviceInstalls.scheme(app(["applications-0.10-build-3", "releases-build-4", "visor"]), queried: queried), "visor")
        XCTAssertNil(DeviceInstalls.scheme(app(["example-oauth-callback"]), queried: queried), "not listed: iOS won't answer")
        XCTAssertNil(DeviceInstalls.scheme(app(["applications-0.10-build-3"]), queried: ["applications-0.10-build-3"]), "a build's own")
    }

    func testTheIPadsTitlesAreTheDetails() {
        let store = store()
        let host = SnapshotHost(RootView().environment(store), size: pad, regular: true)
        XCTAssertEqual(host.columnTitles().sidebar, "")
        XCTAssertEqual(host.columnTitles().detail, "Applications")
        Snapshot.check(host.picture(), named: "pad-nothing-open", kept: SnapshotHost.kept("pad-nothing-open", in: bundle))
        store.selection = "com.example.Visor"
        host.settle()
        XCTAssertEqual(host.columnTitles().sidebar, "")
        XCTAssertEqual(host.columnTitles().detail, "Visor")
        Snapshot.check(host.picture(), named: "pad-app", kept: SnapshotHost.kept("pad-app", in: bundle))
        host.close()
    }
}
