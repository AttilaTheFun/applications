import PipelineSnapshots
import SwiftUI
import XCTest

/// Applications on the Mac, on its fixture: the window titled as Visor's is
/// (the detail's title: "Applications" with nothing open, then the app's
/// name), and the window as its kept pictures.
@MainActor
final class ApplicationsMacTitlesTests: XCTestCase {
    private let package = "tests/mac_tests"

    func testTheWindowsTitleIsTheDetails() throws {
        let store = ApplicationsStore()
        store.showFixture()
        let host = MacSnapshotHost(RootView().environment(store), size: CGSize(width: 1100, height: 760))
        XCTAssertEqual(host.title, "Applications")
        host.check("mac-nothing-open", package: package)
        store.selection = "com.example.Visor"
        host.settle()
        XCTAssertEqual(host.title, "Visor")
        host.check("mac-app", package: package)
    }
}
