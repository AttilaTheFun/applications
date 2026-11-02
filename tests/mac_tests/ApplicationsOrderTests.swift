import XCTest

/// The sidebar's apps by name (A to Z), whatever order the server gives.
@MainActor
final class ApplicationsOrderTests: XCTestCase {
    func testTheSidebarsAppsByName() {
        let store = ApplicationsStore()
        store.showFixture()
        let names = store.listings.map(\.name)
        XCTAssertEqual(names, ["Halo", "Noson", "Visor"], "a beta's name without its mark")
        XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}
