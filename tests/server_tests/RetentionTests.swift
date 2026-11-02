import ApplicationsProtocol
import Foundation
import XCTest
@testable import ApplicationsServer

/// How long builds are kept: production's for good; of the betas, each
/// bundle's newest for good and the others for a week; a pull request's
/// newest, and up to its newest three from the week.
final class RetentionTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private func store() throws -> (BuildStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("retention-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("builds"), withIntermediateDirectories: true)
        return (BuildStore(folder: folder.appendingPathComponent("builds")), folder)
    }

    func testProductionForGoodTheNewestBetaForGoodTheRestForAWeek() throws {
        let (store, folder) = try store()
        let now = Date()
        let production: (Build) -> Bool = { $0.version == "0.1" }
        func add(_ version: String, _ number: String, daysAgo: Double) throws {
            _ = try store.add(package: TestIPA.make(in: folder, version: version, build: number), notes: "",
                              now: now.addingTimeInterval(-daysAgo * day), keeps: production)
        }
        try add("0.1", "1", daysAgo: 10)
        try add("0.2", "2", daysAgo: 9)
        try add("0.2", "3", daysAgo: 3)
        try add("0.3", "4", daysAgo: 0)
        store.pruneAll(keeps: production, now: now)
        XCTAssertEqual(store.all().map(\.buildNumber), ["4", "3", "1"], "a beta nine days old goes; production's and the week's stay")
        store.pruneAll(keeps: production, now: now.addingTimeInterval(30 * day))
        XCTAssertEqual(store.all().map(\.buildNumber), ["4", "1"], "a month on: the newest beta and production's")
    }

    /// By variant: an Alpha a week, a Beta two weeks, Production for good;
    /// each bundle's newest whatever its age.
    func testAnAlphaForAWeekABetaForTwoProductionForGood() throws {
        let (store, folder) = try store()
        let now = Date()
        let production: (Build) -> Bool = { $0.buildVariant == "Production" }
        func add(_ number: String, _ variant: String, daysAgo: Double) throws {
            _ = try store.add(package: TestIPA.make(in: folder, version: "0.10.\(number)", build: "1", variant: variant), notes: "",
                              now: now.addingTimeInterval(-daysAgo * day), keeps: production)
        }
        try add("1", "Production", daysAgo: 40)
        try add("2", "Beta", daysAgo: 10)
        try add("3", "Alpha", daysAgo: 9)
        try add("4", "Alpha", daysAgo: 0)
        store.pruneAll(keeps: production, now: now)
        XCTAssertEqual(store.all().map(\.version), ["0.10.4", "0.10.2", "0.10.1"], "the nine-day Alpha goes; the ten-day Beta stays")
        XCTAssertEqual(store.all().first?.buildVariant, "Alpha")
        store.pruneAll(keeps: production, now: now.addingTimeInterval(5 * day))
        XCTAssertEqual(store.all().map(\.version), ["0.10.4", "0.10.1"], "past two weeks the Beta goes; Production stays")
    }

    /// An AdHoc build goes after a week, even its bundle's newest.
    func testAnAdHocBuildGoesAfterAWeekEvenTheNewest() throws {
        let (store, folder) = try store()
        let now = Date()
        _ = try store.add(package: TestIPA.make(in: folder, version: "0.10.5", build: "1", variant: "Alpha"), notes: "",
                          now: now.addingTimeInterval(-20 * day))
        _ = try store.add(package: TestIPA.make(in: folder, version: "0.10.6", build: "1", variant: "AdHoc"), notes: "",
                          now: now.addingTimeInterval(-8 * day))
        store.pruneAll(keeps: { _ in false }, now: now)
        XCTAssertEqual(store.all().map(\.version), ["0.10.5"], "the eight-day AdHoc goes; the newest Alpha stays")
    }

    func testTheNextBuildNumberIsOnePastAVersionsHighest() throws {
        let (store, folder) = try store()
        _ = try store.add(package: TestIPA.make(in: folder, version: "0.34", build: "20"), notes: "")
        _ = try store.add(package: TestIPA.make(in: folder, version: "0.35", build: "3"), notes: "")
        _ = try store.add(package: TestIPA.make(in: folder, version: "0.35", build: "12"), notes: "",
                          origin: BuildOrigin(commit: "c12", branch: "release-0.35", pullRequest: 116))
        XCTAssertEqual(store.nextBuildNumber(version: "0.35") { _ in true }, 13, "a pull request's builds count too")
        XCTAssertEqual(store.nextBuildNumber(version: "0.36") { _ in true }, 1)
        XCTAssertEqual(store.nextBuildNumber(version: "0.35") { _ in false }, 1, "another app's builds don't")
    }

    func testAPullRequestsNewestAndUpToThreeFromTheWeek() throws {
        let (store, folder) = try store()
        let now = Date()
        for (number, daysAgo) in [("1", 20.0), ("2", 9.0), ("3", 3.0), ("4", 2.0), ("5", 1.0), ("6", 0.0)] {
            _ = try store.add(package: TestIPA.make(in: folder, build: number), notes: "", origin: BuildOrigin(commit: "c\(number)", branch: "idea", pullRequest: 7),
                              now: now.addingTimeInterval(-daysAgo * day))
        }
        store.pruneAll(keeps: { _ in false }, now: now)
        XCTAssertEqual(store.all().map(\.buildNumber), ["6", "5", "4"])
        store.pruneAll(keeps: { _ in false }, now: now.addingTimeInterval(30 * day))
        XCTAssertEqual(store.all().map(\.buildNumber), ["6"], "a month on: its newest alone")
    }
}
