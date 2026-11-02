// The path the apps take to their server, chosen as the owner asked: this
// computer, then the LAN, then the tailnet or the internet — every path
// asked at once, so a silent one is never waited out before the next.

import Foundation
@testable import PipelineClient
import XCTest

final class PathChoiceTests: XCTestCase {
    private let local = "https://127.0.0.1:7461"
    private let lan = "https://10.0.0.49:7461"
    private let tailnet = "https://100.64.0.11:7461"

    /// When each path is asked: kept by the stand-in paths below.
    private actor Asked {
        var times: [String: Date] = [:]
        func note(_ address: String) { times[address] = Date() }
    }

    /// Stand-in paths: each answers (or fails) the given milliseconds after
    /// it is asked; one not in `plan` is refused at once.
    private func paths(_ plan: [String: (ms: UInt64, answers: Bool)], asked: Asked = Asked()) -> @Sendable (String) async -> String? {
        { address in
            await asked.note(address)
            guard let step = plan[address] else { return "refused" }
            try? await Task.sleep(nanoseconds: step.ms * 1_000_000)
            return step.answers ? nil : "no answer"
        }
    }

    private func choose(_ plan: [String: (ms: UInt64, answers: Bool)], asked: Asked = Asked()) async -> (PathProbe, TimeInterval) {
        let start = Date()
        let probe = await ServerClient.probe(ServerClient.candidates([lan, tailnet]), ask: paths(plan, asked: asked))
        return (probe, Date().timeIntervalSince(start))
    }

    func testThisComputerFirst() async {
        let (probe, _) = await choose([local: (50, true), lan: (10, true), tailnet: (5, true)])
        XCTAssertEqual(probe.best, local)
    }

    func testTheLANBeforeTheTailnet() async {
        let (probe, _) = await choose([lan: (300, true), tailnet: (10, true)])
        XCTAssertEqual(probe.best, lan, "the LAN answering a moment after the tailnet is still taken")
        XCTAssertEqual(probe.failures[local], "refused")
    }

    func testTheLANAtOnceWhenItAnswers() async {
        // This device refused at once (a phone's own 127.0.0.1): nothing
        // better is left to wait for.
        let (probe, elapsed) = await choose([lan: (20, true), tailnet: (3000, true)])
        XCTAssertEqual(probe.best, lan)
        XCTAssertLessThan(elapsed, 0.2, "neither the tailnet nor a refused path is waited for once the LAN answers")
    }

    func testTheTailnetWhenTheLANIsSilent() async {
        let (probe, elapsed) = await choose([lan: (4000, false), tailnet: (10, true)])
        XCTAssertEqual(probe.best, tailnet)
        XCTAssertLessThan(elapsed, 1.2, "a silent LAN is given its moment, not waited out")
    }

    func testTheTailnetAtOnceWhenTheLANFails() async {
        // Away from home: the LAN's address goes nowhere at once.
        let (probe, elapsed) = await choose([lan: (5, false), tailnet: (30, true)])
        XCTAssertEqual(probe.best, tailnet)
        XCTAssertLessThan(elapsed, 0.2, "nothing better is left to wait for")
    }

    func testEveryPathAskedAtOnce() async {
        let asked = Asked()
        let (probe, elapsed) = await choose([lan: (400, false), tailnet: (400, false)], asked: asked)
        let times = await asked.times
        XCTAssertEqual(Set(times.keys), [local, lan, tailnet])
        let spread = (times.values.max() ?? Date()).timeIntervalSince(times.values.min() ?? Date())
        XCTAssertLessThan(spread, 0.2, "all asked together")
        XCTAssertLessThan(elapsed, 1.5, "one after another would take longer")
        XCTAssertNil(probe.best)
    }

    func testNoneAnsweringSaysWhyEach() async {
        let (probe, _) = await choose([lan: (10, false), tailnet: (10, false)])
        XCTAssertNil(probe.best)
        XCTAssertEqual(probe.failures, [local: "refused", lan: "no answer", tailnet: "no answer"])
    }

    func testThisComputerIsAskedToo() {
        XCTAssertEqual(ServerClient.candidates([lan, tailnet]), [local, lan, tailnet])
    }

    func testPathsRanked() {
        XCTAssertEqual(ServerClient.rank(local), 0)
        XCTAssertEqual(ServerClient.rank(lan), 1)
        XCTAssertEqual(ServerClient.rank("https://example-mac.local:7461"), 1)
        XCTAssertEqual(ServerClient.rank("https://10.0.0.5:7461"), 1)
        XCTAssertEqual(ServerClient.rank(tailnet), 2)
        XCTAssertEqual(ServerClient.rank("https://example.com:7461"), 2)
    }
}
