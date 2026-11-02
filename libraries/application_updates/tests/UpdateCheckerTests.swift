import ApplicationUpdates
import Foundation
import XCTest

/// The app's check at launch: its build written, and the user told of a
/// newer one once, in the foreground.
final class UpdateCheckerTests: XCTestCase {
    private var temporary = TemporaryDatabase()
    private let app = InstalledApp(bundleID: "com.example.Visor", version: "0.39.2", build: "1")

    override func tearDown() {
        temporary.remove()
        super.tearDown()
    }

    private func latest(_ version: String, in store: AppGroupStore) async throws {
        try await store.setLatest([LatestBuild(bundleID: app.bundleID, version: version, build: "1",
                                               installURL: URL(string: "itms-services://?action=download-manifest&url=x"))])
    }

    func testNothingKnownYetWritesTheBuildAndTellsNothing() async throws {
        let store = AppGroupStore(fileURL: temporary.file)
        let presenter = FakePresenter()
        let found = try await UpdateChecker(store: store, app: app, presenter: presenter).check()
        XCTAssertEqual(found, .unknown)
        let record = try await store.record(bundleID: app.bundleID)
        XCTAssertEqual(record?.installedVersion, "0.39.2")
        let presented = await presenter.presented
        XCTAssertEqual(presented, [])
    }

    func testUpToDate() async throws {
        let store = AppGroupStore(fileURL: temporary.file)
        try await latest("0.39.2", in: store)
        let presenter = FakePresenter()
        let found = try await UpdateChecker(store: store, app: app, presenter: presenter).check()
        XCTAssertEqual(found, .upToDate)
        let presented = await presenter.presented
        XCTAssertEqual(presented, [])
    }

    func testANewerBuildIsToldOnce() async throws {
        let store = AppGroupStore(fileURL: temporary.file)
        try await latest("0.40.1", in: store)
        let presenter = FakePresenter()
        let checker = UpdateChecker(store: store, app: app, presenter: presenter)
        let found = try await checker.check()
        try await checker.check()
        guard case .available(let update) = found else { return XCTFail("no update: \(found)") }
        XCTAssertEqual(update.version, "0.40.1")
        XCTAssertEqual(update.installedVersion, "0.39.2")
        XCTAssertEqual(update.installURL?.scheme, "itms-services")
        var presented = await presenter.presented
        XCTAssertEqual(presented, [update], "told once")

        // Applications syncs a newer one while the app runs: told of that too.
        try await latest("0.40.2", in: store)
        try await checker.check()
        presented = await presenter.presented
        XCTAssertEqual(presented.map(\.version), ["0.40.1", "0.40.2"])
    }

    func testToldOnlyInTheForeground() async throws {
        let store = AppGroupStore(fileURL: temporary.file)
        try await latest("0.40.1", in: store)
        let presenter = FakePresenter()
        await presenter.setForeground(false)
        let checker = UpdateChecker(store: store, app: app, presenter: presenter)
        try await checker.check()
        var presented = await presenter.presented
        XCTAssertEqual(presented, [], "launched in the background")
        await presenter.setForeground(true)
        try await checker.check()
        presented = await presenter.presented
        XCTAssertEqual(presented.map(\.version), ["0.40.1"], "told once it came forward")
    }

    func testAnOlderLatestIsNoUpdate() async throws {
        let store = AppGroupStore(fileURL: temporary.file)
        try await latest("0.38.9", in: store)
        let found = try await UpdateChecker(store: store, app: app, presenter: FakePresenter()).check()
        XCTAssertEqual(found, .upToDate, "a build newer than any published")
    }

    func testApplicationsWritesItsBuildButTellsNothing() async throws {
        let store = AppGroupStore(fileURL: temporary.file)
        try await latest("0.40.1", in: store)
        let presenter = FakePresenter()
        let found = try await UpdateChecker(store: store, app: app, presenter: presenter, tells: false).check()
        guard case .available = found else { return XCTFail("no update: \(found)") }
        let presented = await presenter.presented
        XCTAssertEqual(presented, [])
    }

    func testTheNotificationCarriesTheUpdate() {
        let update = AvailableUpdate(bundleID: "com.example.Visor", version: "0.40.1", build: "1", installURL: URL(string: "https://server/a.zip"),
                                     installedVersion: "0.39.2", installedBuild: nil)
        let info: [AnyHashable: Any] = update.userInfo
        XCTAssertEqual(AvailableUpdate(userInfo: info), update)
        XCTAssertNil(AvailableUpdate(userInfo: ["build": "b1"]), "another notification's")
    }
}
