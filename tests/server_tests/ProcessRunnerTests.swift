import Foundation
import PipelineServer
import XCTest

/// A command given a time limit is stopped when it overruns it, and fails
/// saying so; one that ends in time is let be.
final class ProcessRunnerTests: XCTestCase {
    func testACommandPastItsTimeIsStopped() throws {
        let started = Date()
        XCTAssertThrowsError(try ProcessRunner.run("/bin/sleep", ["30"], timeout: 1)) { error in
            XCTAssertTrue("\(error)".contains("stopped after 1 s"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "stopped, not waited out")
        XCTAssertEqual(try ProcessRunner.run("/bin/echo", ["in time"], timeout: 10), Data("in time\n".utf8))
    }
}
