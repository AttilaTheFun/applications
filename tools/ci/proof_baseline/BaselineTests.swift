// What a proof's screens are compared with, for each kind of run: a pull
// request's base branch, a push's commit before, a release's release
// before, a CI run by hand's release before the commit, main by hand
// outside CI; and the release before among a repository's tags.

import ProofBaseline
import XCTest

final class BaselineTests: XCTestCase {
    private let commit = "3b86b9c0aa1c2b3d4e5f60718293a4b5c6d7e8f9"

    func testAPullRequestIsComparedWithItsBaseBranch() {
        XCTAssertEqual(Baseline.choose(event: "pull_request", baseRef: "main", refName: "44/merge", commit: commit),
                       Baseline(ref: "main", revision: "refs/remotes/origin/main",
                                fetch: ["--no-tags", "--depth=1", "origin", "+refs/heads/main:refs/remotes/origin/main"]))
        XCTAssertEqual(Baseline.choose(event: "pull_request", baseRef: "release-0.35", refName: "44/merge", commit: commit)?.ref,
                       "release-0.35")
        XCTAssertNil(Baseline.choose(event: "pull_request", baseRef: "", refName: "44/merge", commit: commit))
    }

    func testAPushIsComparedWithTheCommitBefore() {
        XCTAssertEqual(Baseline.choose(event: "push", baseRef: "", refName: "main", commit: commit),
                       Baseline(ref: "main", revision: commit + "^", fetch: ["--no-tags", "--depth=2", "origin", commit]))
    }

    func testAReleaseIsComparedWithTheReleaseBefore() {
        let tags = ["v0.9.2", "v0.10.1", "v0.9.10", "inbox", "v0.10.0", "v1.0", "v0.11.0", "vnext"]
        XCTAssertEqual(Baseline.choose(event: "release", baseRef: "", refName: "v0.10.1", commit: commit, tags: tags),
                       Baseline(ref: "v0.10.0", revision: "refs/tags/v0.10.0",
                                fetch: ["--no-tags", "--depth=1", "origin", "+refs/tags/v0.10.0:refs/tags/v0.10.0"]))
        XCTAssertEqual(Baseline.previousTag("v0.10.0", among: tags), "v0.9.10", "by number, not by letter")
        XCTAssertEqual(Baseline.previousTag("v1.0.0", among: tags), "v1.0")
        XCTAssertNil(Baseline.previousTag("v0.9.2", among: tags), "the first release has none before it")
        XCTAssertNil(Baseline.choose(event: "release", baseRef: "", refName: "v0.9.2", commit: commit, tags: tags))
        XCTAssertNil(Baseline.previousTag("latest", among: tags))
    }

    func testRunInCIByHandItIsTheReleaseBefore() {
        // The tags before the commit, as ios_lease_tests.sh lists them.
        let tags = ["v0.9.2", "v0.10.4", "inbox", "v0.10.12", "v0.10.9"]
        XCTAssertEqual(Baseline.choose(event: "workflow_dispatch", baseRef: "", refName: "main", commit: commit, tags: tags),
                       Baseline(ref: "v0.10.12", revision: "refs/tags/v0.10.12",
                                fetch: ["--no-tags", "--depth=1", "origin", "+refs/tags/v0.10.12:refs/tags/v0.10.12"]))
        XCTAssertEqual(Baseline.choose(event: "workflow_dispatch", baseRef: "", refName: "main", commit: commit, tags: ["inbox"]),
                       Baseline(ref: "the commit before", revision: commit + "^", fetch: ["--no-tags", "--depth=2", "origin", commit]),
                       "no release before it: the commit before")
    }

    func testByHandItIsMain() {
        XCTAssertEqual(Baseline.choose(event: "", baseRef: "", refName: "", commit: commit)?.revision, "refs/remotes/origin/main")
    }
}
