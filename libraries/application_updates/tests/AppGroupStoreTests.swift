import ApplicationUpdates
import Foundation
import SwiftSQL
import XCTest

/// The shared database as several processes use it: each store here opens
/// the file on its own, as another app would.
final class AppGroupStoreTests: XCTestCase {
    private var temporary = TemporaryDatabase()

    override func tearDown() {
        temporary.remove()
        super.tearDown()
    }

    private func store(at time: TimeInterval = 1_000) -> AppGroupStore {
        AppGroupStore(fileURL: temporary.file, now: { Date(timeIntervalSince1970: time) })
    }

    func testMadeOnFirstUseInWriteAheadLogMode() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.file.path))
        let records = try await store().records()
        XCTAssertEqual(records, [])
        let database = try Database(path: temporary.file.path)
        XCTAssertEqual(try database.query("PRAGMA journal_mode") { $0.text(0) }, ["wal"])
        XCTAssertEqual(try database.query("PRAGMA user_version") { $0.int(0) }, [2])
    }

    func testTheInstalledBuildIsWrittenOnlyWhenItDiffers() async throws {
        let store = store()
        let first = try await store.recordInstalled(bundleID: "com.example.Visor", version: "0.39.2", build: "1")
        let again = try await store.recordInstalled(bundleID: "com.example.Visor", version: "0.39.2", build: "1")
        let newer = try await store.recordInstalled(bundleID: "com.example.Visor", version: "0.39.3", build: "1")
        XCTAssertTrue(first)
        XCTAssertFalse(again)
        XCTAssertTrue(newer)
        let record = try await store.record(bundleID: "com.example.Visor")
        XCTAssertEqual(record?.installedVersion, "0.39.3")
        XCTAssertNil(record?.latestVersion)
    }

    /// One bundle id is one app installed at a time: each launch writes its
    /// variant with its version, so Production of the same version over an
    /// Alpha is written too, and the last launched is the one recorded.
    func testTheInstalledVariantIsTheLastLaunched() async throws {
        let store = store()
        let alpha = try await store.recordInstalled(bundleID: "com.example.Visor", version: "0.41.30", build: "1", variant: "Alpha")
        let production = try await store.recordInstalled(bundleID: "com.example.Visor", version: "0.41.30", build: "1", variant: "Production")
        let again = try await store.recordInstalled(bundleID: "com.example.Visor", version: "0.41.30", build: "1", variant: "Production")
        let adHoc = try await store.recordInstalled(bundleID: "com.example.Visor", version: "0.41.31", build: "1", variant: "AdHoc")
        XCTAssertEqual([alpha, production, again, adHoc], [true, true, false, true])
        let record = try await store.record(bundleID: "com.example.Visor")
        XCTAssertEqual(record?.installedVersion, "0.41.31")
        XCTAssertEqual(record?.installedVariant, "AdHoc")
        // A build that doesn't say its variant clears the one before.
        try await store.recordInstalled(bundleID: "com.example.Visor", version: "0.41.32", build: "1")
        let unsaid = try await store.record(bundleID: "com.example.Visor")
        XCTAssertNil(unsaid?.installedVariant)
    }

    /// Applications writes the newest builds, the app its own installed
    /// build, each in a process of its own: neither undoes the other.
    func testApplicationsAndAnAppEachWriteTheirOwnColumns() async throws {
        let applications = store(at: 1_000)
        let app = store(at: 2_000)
        let url = URL(string: "itms-services://?action=download-manifest&url=https%3A%2F%2Fserver%2Fmanifest.plist")
        try await applications.setLatest([LatestBuild(bundleID: "com.example.Visor", version: "0.40.1", build: "1", installURL: url)])
        try await app.recordInstalled(bundleID: "com.example.Visor", version: "0.39.2", build: "1")
        let seen = try await applications.record(bundleID: "com.example.Visor")
        XCTAssertEqual(seen, AppRecord(bundleID: "com.example.Visor", latestVersion: "0.40.1", latestBuild: "1", installURL: url,
                                       installedVersion: "0.39.2", installedBuild: "1", updatedAt: Date(timeIntervalSince1970: 2_000)))
        XCTAssertEqual(seen?.updateAvailable, true)
    }

    func testTheLatestBuildsAreWrittenTogetherAndOnlyWhenTheyDiffer() async throws {
        let store = store()
        let builds = [
            LatestBuild(bundleID: "com.example.Visor", version: "0.40.1", build: "1", installURL: URL(string: "https://server/a.zip")),
            LatestBuild(bundleID: "com.example.Visor.Beta", version: "0.40.7", build: "1", installURL: URL(string: "https://server/b.zip")),
        ]
        let first = try await store.setLatest(builds)
        let again = try await store.setLatest(builds)
        let moved = try await store.setLatest([LatestBuild(bundleID: "com.example.Visor.Beta", version: "0.40.8", build: "1",
                                                           installURL: URL(string: "https://server/c.zip"))])
        XCTAssertTrue(first)
        XCTAssertFalse(again)
        XCTAssertTrue(moved)
        let records = try await store.records()
        XCTAssertEqual(records.map(\.bundleID), ["com.example.Visor", "com.example.Visor.Beta"], "a beta is a row of its own")
        XCTAssertEqual(records.map(\.latestVersion), ["0.40.1", "0.40.8"])
        XCTAssertEqual(records.last?.installURL, URL(string: "https://server/c.zip"))
    }

    /// Two processes making a new database at once, and writing at once:
    /// one makes the tables, and every write lands (the busy timeout waits
    /// out the other's lock).
    func testManyWritersAtOnce() async throws {
        let stores = [store(), store()]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                let store = stores[index % 2]
                group.addTask {
                    try await store.recordInstalled(bundleID: "com.example.App\(index)", version: "1.\(index)", build: nil)
                }
            }
            try await group.waitForAll()
        }
        let records = try await stores[0].records()
        XCTAssertEqual(records.count, 40)
    }

    /// In write-ahead-log mode another process reads while one is in the
    /// middle of a write.
    func testReadsWhileAnotherProcessWrites() async throws {
        let store = store()
        try await store.recordInstalled(bundleID: "com.example.Visor", version: "0.39.2", build: "1")
        let writer = try Database(path: temporary.file.path)
        try writer.execute("BEGIN IMMEDIATE")
        try writer.run("UPDATE apps SET installed_version = '0.39.9'")
        let read = try await store.record(bundleID: "com.example.Visor")
        XCTAssertEqual(read?.installedVersion, "0.39.2", "the last committed row")
        try writer.execute("COMMIT")
        let after = try await store.record(bundleID: "com.example.Visor")
        XCTAssertEqual(after?.installedVersion, "0.39.9")
    }

    /// A database a newer build of the library migrated further is still
    /// read and written by this one (migrations only add).
    func testANewerDatabaseIsUsedAsItIs() async throws {
        try await store().recordInstalled(bundleID: "com.example.Visor", version: "0.39.2", build: "1")
        let database = try Database(path: temporary.file.path)
        try database.execute("ALTER TABLE apps ADD COLUMN later TEXT; PRAGMA user_version = 3")
        database.close()
        let other = store()
        try await other.setLatest([LatestBuild(bundleID: "com.example.Visor", version: "0.40.1", build: "1", installURL: nil)])
        let record = try await other.record(bundleID: "com.example.Visor")
        XCTAssertEqual(record?.latestVersion, "0.40.1")
        XCTAssertEqual(try Database(path: temporary.file.path).query("PRAGMA user_version") { $0.int(0) }, [3])
    }

    func testAnInstallRequestIsOneABundleAndTakenOnce() async throws {
        let app = store()
        let applications = store()
        let other = store()
        try await app.requestInstall(InstallRequest(bundleID: "com.example.Visor", version: "0.40.0", build: "1",
                                                    requestedBy: "com.example.Visor", requestedAt: Date(timeIntervalSince1970: 10)))
        try await app.requestInstall(InstallRequest(bundleID: "com.example.Visor", version: "0.40.1", build: "1",
                                                    requestedBy: "com.example.Visor", requestedAt: Date(timeIntervalSince1970: 20)))
        try await app.requestInstall(InstallRequest(bundleID: "com.example.Reviews", version: "0.8.0", build: nil,
                                                    requestedBy: "com.example.Reviews", requestedAt: Date(timeIntervalSince1970: 15)))
        let waiting = try await applications.installRequests()
        XCTAssertEqual(waiting.map(\.bundleID), ["com.example.Reviews", "com.example.Visor"], "oldest first")
        XCTAssertEqual(waiting.last?.version, "0.40.1", "the later request replaced the earlier")

        // Two copies of Applications (production's and the beta's) take at once.
        async let first = applications.takeInstallRequests()
        async let second = other.takeInstallRequests()
        let taken = try await first + second
        XCTAssertEqual(taken.map(\.bundleID).sorted(), ["com.example.Reviews", "com.example.Visor"], "each taken once")
        let left = try await applications.installRequests()
        XCTAssertEqual(left, [])
    }

    func testARequestTakenBack() async throws {
        let store = store()
        try await store.requestInstall(InstallRequest(bundleID: "com.example.Visor", version: "0.40.1", build: "1",
                                                      requestedBy: "com.example.Visor", requestedAt: Date()))
        try await store.cancelInstallRequest(bundleID: "com.example.Visor")
        let left = try await store.installRequests()
        XCTAssertEqual(left, [])
    }
}
