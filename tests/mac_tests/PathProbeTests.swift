import Foundation
import PipelineClient
import XCTest

/// Why a path to the server did not answer, as Settings says it beside
/// "Not reached": the LAN closed to this app (said only in the path the
/// system puts beside the error), a refused port, no answer; and each
/// path asked, with its reason.
final class PathProbeTests: XCTestCase {
    func testALocalNetworkRefusedIsSaid() {
        let denied = URLError(.notConnectedToInternet,
                              userInfo: ["_NSURLErrorNWPathKey": "unsatisfied (Local network prohibited), interface: en0[802.11]"])
        XCTAssertEqual(PathProbe.why(denied), PathProbe.localNetwork)
        XCTAssertTrue(PathProbe(failures: ["https://10.0.0.49:7461": PathProbe.why(denied)]).localNetworkDenied)
        XCTAssertEqual(PathProbe.why(URLError(.notConnectedToInternet)), "no network")
        XCTAssertEqual(PathProbe.why(URLError(.timedOut)), "no answer")
        XCTAssertEqual(PathProbe.why(URLError(.cannotConnectToHost)), "refused")
    }

    func testEachPathAskedSaysWhy() async {
        // Nothing listens on port 9 here: refused at once.
        let code = ConnectionCode(id: "test", name: "Nowhere", addresses: ["https://127.0.0.1:9"], password: "pw", ca: "00")
        let probe = await ServerClient(code: code, pinning: ServerTrust(fingerprint: "00")).probe()
        XCTAssertNil(probe.best)
        XCTAssertEqual(probe.failures["https://127.0.0.1:9"], "refused")
    }

    @MainActor
    func testPathsAreNamedAsSettingsSaysThem() {
        XCTAssertEqual(ServerSection.name("https://10.0.0.49:7461"), "10.0.0.49 (LAN)")
        XCTAssertEqual(ServerSection.name("https://100.64.0.11:7461"), "100.64.0.11 (tailnet)")
        XCTAssertEqual(ServerSection.name("https://127.0.0.1:7461"), "this Mac")
    }
}
