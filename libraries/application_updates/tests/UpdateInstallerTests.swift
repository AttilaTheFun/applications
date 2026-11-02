import ApplicationUpdates
import Foundation
import XCTest

/// Installing: the handler's way, iOS's install link, or Applications asked
/// through the database and the app quit.
final class UpdateInstallerTests: XCTestCase {
    private var temporary = TemporaryDatabase()
    private let update = AvailableUpdate(bundleID: "com.example.Visor", version: "0.40.1", build: "1",
                                         installURL: URL(string: "itms-services://?action=download-manifest&url=x"),
                                         installedVersion: "0.39.2", installedBuild: "1")

    override func tearDown() {
        temporary.remove()
        super.tearDown()
    }

    private func installer(_ platform: UpdatePlatform, system: FakeSystem, handler: UpdateHandler? = nil) -> UpdateInstaller {
        UpdateInstaller(store: AppGroupStore(fileURL: temporary.file), system: system, platform: platform, handler: handler,
                        requester: "com.example.Visor", now: { Date(timeIntervalSince1970: 50) })
    }

    func testAnIPhoneOpensTheInstallLink() async throws {
        let system = FakeSystem()
        let outcome = try await installer(.iOS, system: system).install(update)
        XCTAssertEqual(outcome, .openedInstallLink)
        let events = await system.events
        XCTAssertEqual(events, ["open itms-services://?action=download-manifest&url=x"], "iOS ends the app itself")
    }

    func testAnIPhoneWithoutALinkOrRefused() async throws {
        let system = FakeSystem()
        var noLink = update
        noLink.installURL = nil
        await XCTAssertThrowsAsync(try await self.installer(.iOS, system: system).install(noLink), UpdateInstallError.noInstallURL)
        await system.setOpensURLs(false)
        await XCTAssertThrowsAsync(try await self.installer(.iOS, system: system).install(self.update), UpdateInstallError.installLinkRefused)
    }

    func testAMacAsksApplicationsThenQuits() async throws {
        let system = FakeSystem()
        let installer = installer(.macOS, system: system)
        let outcome = try await installer.install(update)
        XCTAssertEqual(outcome, .askedApplications)
        let events = await system.events
        XCTAssertEqual(events, ["changed", "open Applications", "terminate"])
        let requests = try await installer.store.installRequests()
        XCTAssertEqual(requests, [InstallRequest(bundleID: "com.example.Visor", version: "0.40.1", build: "1",
                                                 requestedBy: "com.example.Visor", requestedAt: Date(timeIntervalSince1970: 50))])
    }

    func testAMacWithoutApplicationsKeepsRunning() async throws {
        let system = FakeSystem()
        await system.setHasApplications(false)
        let installer = installer(.macOS, system: system)
        await XCTAssertThrowsAsync(try await installer.install(self.update), UpdateInstallError.applicationsNotInstalled)
        let events = await system.events
        XCTAssertEqual(events, ["changed"], "not quit")
        let requests = try await installer.store.installRequests()
        XCTAssertEqual(requests, [], "the request taken back")
    }

    func testAnAppWithAHandlerUpdatesItself() async throws {
        let system = FakeSystem()
        let given = Given()
        let outcome = try await installer(.macOS, system: system, handler: { await given.set($0) }).install(update)
        XCTAssertEqual(outcome, .handled)
        let handled = await given.update
        XCTAssertEqual(handled, update)
        let events = await system.events
        XCTAssertEqual(events, [], "neither Applications nor quitting")
    }
}
