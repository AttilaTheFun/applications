import ApplicationUpdates
import XCTest

/// Versions in order as numbers, part by part, then by build.
final class AppVersionTests: XCTestCase {
    func testPartsAreNumbersNotText() {
        XCTAssertLessThan(AppVersion("0.9.34"), AppVersion("0.10.2"))
        XCTAssertLessThan(AppVersion("0.10.2"), AppVersion("0.10.10"))
        XCTAssertLessThan(AppVersion("1.99"), AppVersion("2.0"))
        XCTAssertGreaterThan(AppVersion("0.39.12"), AppVersion("0.39.9"))
    }

    func testAMissingPartIsZero() {
        XCTAssertEqual(AppVersion("0.10"), AppVersion("0.10.0"))
        XCTAssertLessThan(AppVersion("0.10"), AppVersion("0.10.1"))
        XCTAssertEqual(AppVersion("1.02"), AppVersion("1.2"), "leading zeros are the same number")
    }

    func testTheBuildDecidesBetweenTheSameVersions() {
        XCTAssertLessThan(AppVersion("0.23", build: "22"), AppVersion("0.23", build: "23"))
        XCTAssertLessThan(AppVersion("0.23", build: "9"), AppVersion("0.23", build: "10"))
        XCTAssertLessThan(AppVersion("0.22", build: "99"), AppVersion("0.23", build: "1"), "the version before the build")
    }

    func testAnUnknownBuildDoesNotDecide() {
        XCTAssertEqual(AppVersion("0.38.4", build: nil), AppVersion("0.38.4", build: "1"))
        XCTAssertEqual(AppVersion("0.38.4", build: ""), AppVersion("0.38.4", build: "7"))
    }

    func testAReleaseIsAfterItsSuffixedBuilds() {
        XCTAssertLessThan(AppVersion("1.0b2"), AppVersion("1.0"))
        XCTAssertLessThan(AppVersion("1.0b2"), AppVersion("1.0b3"))
        XCTAssertLessThan(AppVersion("1.0"), AppVersion("1.1b1"))
    }

    func testLongNumbersDoNotOverflow() {
        XCTAssertLessThan(AppVersion("1.99999999999999999999999"), AppVersion("1.100000000000000000000000"))
    }

    func testDescription() {
        XCTAssertEqual(AppVersion("0.38.4", build: "1").description, "0.38.4")
        XCTAssertEqual(AppVersion("0.23", build: "23").description, "0.23 (23)")
        XCTAssertEqual(AppVersion("0.10.2").description, "0.10.2")
    }
}
