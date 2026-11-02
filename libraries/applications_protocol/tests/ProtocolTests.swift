// What the server and the app say to each other, apart from either: the
// builds, where an installed one stands, their titles and notes, channels
// and betas. Portable, as the protocol is: run on Linux and the Mac alike.

import Foundation
import PipelineClient
import XCTest
@testable import ApplicationsProtocol

final class ProtocolTests: XCTestCase {
    /// Where a device stands: by the executable's UUID where both say it,
    /// else by the numbers; nothing said is unknown.
    func testWhereTheInstalledBuildStands() {
        func build(_ version: String, _ number: String, _ uuid: String?) -> Build {
            Build(id: number, bundleID: "app", name: "App", version: version, buildNumber: number, published: Date(), size: 0,
                  executableUUID: uuid)
        }
        let app = AppBuilds(bundleID: "app", name: "App", builds: [build("0.24", "24", "C"), build("0.24", "24", "B"), build("0.23", "23", "A")])
        func installed(_ version: String, _ number: String, _ uuid: String = "") -> InstalledBuild {
            InstalledBuild(bundleID: "app", version: version, buildNumber: number, executableUUID: uuid)
        }
        XCTAssertEqual(app.standing(nil), .unknown)
        XCTAssertEqual(app.standing(installed("0.24", "24", "C")), .upToDate)
        XCTAssertEqual(app.standing(installed("0.24", "24", "B")), .updateAvailable, "same numbers, an older build")
        XCTAssertEqual(app.standing(installed("0.23", "23", "A")), .updateAvailable)
        XCTAssertEqual(app.standing(installed("0.25", "25", "Z")), .upToDate, "newer than any published")
        XCTAssertEqual(app.standing(installed("0.24", "24", "Z")), .updateAvailable, "a build of its own with the same numbers")
        XCTAssertEqual(app.standing(installed("0.24", "24")), .upToDate, "no UUID: the numbers decide")
        XCTAssertEqual(app.standing(installed("0.9", "9")), .updateAvailable)
        XCTAssertEqual(InstalledBuild.compare("0.10", "0.9"), .orderedDescending)
        XCTAssertEqual(app.build(installed: installed("0.24", "24", "B"))?.executableUUID, "B")
        XCTAssertEqual(app.build(installed: installed("0.23", "23"))?.executableUUID, "A")
    }

    /// One bundle id is one app installed at a time, its Alpha's, Beta's,
    /// AdHoc's and Production's builds listed apart: the build installed is
    /// held by one group: of its executable, else of its variant, else of
    /// its numbers, else production's. A build's variant is its
    /// BuildVariant, else its channel's.
    func testTheInstalledBuildIsHeldByOneGroup() {
        func build(_ id: String, _ version: String, _ channel: ReleaseChannel, _ variant: String?, _ uuid: String? = nil) -> Build {
            Build(id: id, bundleID: "app", name: "App", version: version, buildNumber: "1", published: Date(), size: 0,
                  executableUUID: uuid, channel: channel, buildVariant: variant)
        }
        let alpha = AppBuilds(bundleID: "app", name: "App", builds: [build("a", "0.10.40", .beta, "Alpha", "A"), build("o", "0.10.39", .beta, nil)])
        let production = AppBuilds(bundleID: "app", name: "App", builds: [build("p", "0.10.38", .production, "Production", "P")])
        XCTAssertEqual(alpha.builds.map(\.variant), ["Alpha", "Alpha"])
        XCTAssertEqual(production.builds.map(\.variant), ["Production"])
        func installed(_ version: String, _ variant: String?, _ uuid: String = "") -> InstalledBuild {
            InstalledBuild(bundleID: "app", version: version, buildNumber: "1", executableUUID: uuid, variant: variant)
        }
        let groups = [alpha, production]
        func holder(_ build: InstalledBuild) -> String? { AppBuilds.holder(of: build, among: groups)?.builds.first?.id }
        XCTAssertEqual(holder(installed("0.10.38", "Production")), "p")
        XCTAssertEqual(alpha.standing(installed("0.10.38", "Production")), .updateAvailable, "alone, the numbers would claim the Alpha's group too")
        XCTAssertEqual(holder(installed("0.10.41", "Alpha")), "a", "an Alpha not published here: its variant's")
        XCTAssertEqual(holder(installed("0.10.40", nil, "A")), "a", "by its executable")
        XCTAssertEqual(holder(installed("0.10.39", nil)), "a", "by its numbers")
        XCTAssertEqual(holder(installed("0.9.1", nil)), "p", "unknown and unsaid: production's")
        XCTAssertNil(holder(installed("0.10.41", "AdHoc")), "a variant none is of")
    }

    /// The apps list's four states: Install when the app isn't here,
    /// Unknown when it is but hasn't said which build, Update when it said
    /// one older than the row's newest (of any variant: one bundle id is one
    /// app), Open when it said the newest or newer.
    func testTheListSaysInstallUnknownUpdateOrOpen() {
        func build(_ id: String, _ version: String) -> Build {
            Build(id: id, bundleID: "app", name: "App", version: version, buildNumber: "1", published: Date(), size: 0,
                  buildVariant: "Alpha")
        }
        let alpha = AppBuilds(bundleID: "app", name: "App", builds: [build("b", "0.43.114"), build("a", "0.43.113")])
        func said(_ version: String, _ variant: String? = "Alpha") -> InstalledBuild {
            InstalledBuild(bundleID: "app", version: version, buildNumber: "1", variant: variant)
        }
        XCTAssertEqual(alpha.listedState(here: false, installed: nil), .install)
        XCTAssertEqual(alpha.listedState(here: false, installed: said("0.43.114")), .install, "said, then deleted")
        XCTAssertEqual(alpha.listedState(here: nil, installed: nil), .install, "no scheme to ask, nothing said")
        XCTAssertEqual(alpha.listedState(here: true, installed: nil), .unknown, "here, not opened since it could say")
        XCTAssertEqual(alpha.listedState(here: true, installed: said("0.43.113")), .update)
        XCTAssertEqual(alpha.listedState(here: true, installed: said("0.43.20", "Production")), .update, "another variant, older")
        XCTAssertEqual(alpha.listedState(here: true, installed: said("0.43.114")), .open)
        XCTAssertEqual(alpha.listedState(here: true, installed: said("0.43.115", "AdHoc")), .open, "newer than any published")
        XCTAssertEqual(alpha.listedState(here: nil, installed: said("0.43.114")), .open, "no scheme to ask: taken at its word")
    }

    /// An app's bundle ids from before one bundle id an app: its beta's,
    /// and on a Mac its `.Mac` and `.Mac.Beta`; nothing else.
    func testAnAppsEarlierBundleIDs() {
        let id = "com.example.Applications"
        for old in [id + ".Beta", id + ".Mac", id + ".Mac.Beta"] { XCTAssertTrue(BundleVariant.isEarlierID(old, of: id), old) }
        for other in [id, "com.example.Visor", id + ".Widget", "com.example.ApplicationsServer"] {
            XCTAssertFalse(BundleVariant.isEarlierID(other, of: id), other)
        }
    }

    /// From 0.38 a build is a version of its own, and says only that: an
    /// Apple build's number is 1, an Android build's versionCode the
    /// version as a number (0.38.1 is 38001). Before, the version and the
    /// build.
    func testABuildOfItsOwnVersionSaysOnlyTheVersion() {
        func title(_ version: String, _ number: String, _ platform: String = "ios") -> String {
            Build(id: "b", bundleID: "app", name: "App", version: version, buildNumber: number, platform: platform, published: Date(), size: 0,
                  notes: "").versionTitle
        }
        XCTAssertEqual(title("0.38.7", "1"), "0.38.7")
        XCTAssertEqual(title("0.38.1", "38001", "android"), "0.38.1")
        XCTAssertEqual(title("1.2.3", "1002003", "android"), "1.2.3")
        XCTAssertEqual(title("0.38.1", "66", "android"), "0.38.1 (66)", "a code that is not the version's")
        XCTAssertEqual(title("0.35", "21"), "0.35 (21)")
        XCTAssertEqual(Build.versionCode("0.38.12"), 38012)
        XCTAssertEqual(BuildNumber(app: "Playground", version: "0.38.1", build: 38001, commit: "94c358c").title, "0.38.1")
    }

    /// Notes as agents write them: the first line is the summary (the
    /// push's text), then sections of lines and bullets.
    func testReleaseNotesHaveASummaryAndSections() {
        let notes = ReleaseNotes("""
        Dictation in the composer; attachments open in Quick Look.
        Built from release-0.24.

        ## What's new
        - The microphone dictates into the draft.
        - Attachments are tiles.

        ## What to test
        * Dictate, edit, send.
        ## Empty
        """)
        XCTAssertEqual(notes.summary, "Dictation in the composer; attachments open in Quick Look.")
        XCTAssertEqual(notes.lead, ["Built from release-0.24."])
        XCTAssertEqual(notes.sections.map(\.title), ["What's new", "What to test"])
        XCTAssertEqual(notes.sections[0].lines, ["- The microphone dictates into the draft.", "- Attachments are tiles."])
        XCTAssertEqual(ReleaseNotes.unmarked(notes.sections[1].lines[0]), "Dictate, edit, send.")
        XCTAssertEqual(ReleaseNotes("## What's new\n- Faster").summary, "Faster", "no first line: the first bullet")
        XCTAssertEqual(ReleaseNotes("").summary, "")
    }

    /// "alpha", as beta was named, reads as beta wherever it was kept (a
    /// build); a channel is written by its new name, and nothing else reads
    /// as one. (The server's channels.json: its own tests.)
    func testAlphaReadsAsBeta() throws {
        XCTAssertEqual(try JSONDecoder().decode([ReleaseChannel].self, from: Data(#"["alpha","beta","production"]"#.utf8)),
                       [.beta, .beta, .production])
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([ReleaseChannel.beta]), as: UTF8.self), #"["beta"]"#)
        XCTAssertThrowsError(try JSONDecoder().decode([ReleaseChannel].self, from: Data(#"["gamma"]"#.utf8)))
        let kept = #"{"id":"b","bundleID":"app","name":"App","version":"0.1","buildNumber":"1","platform":"ios","published":0,"#
            + #""size":0,"notes":"","hasIcon":false,"downloadKey":"","channel":"alpha"}"#
        let build = try WireCoding.decoder().decode(Build.self, from: Data(kept.utf8))
        XCTAssertEqual(build.channel, .beta)
    }

    /// `<id>.Beta` is the beta of `<id>`, one app: the same production id,
    /// and the production's name for "<App> β". Another id, or a name
    /// without the mark, stays as it is.
    func testABetaIsItsProductionsApp() {
        XCTAssertTrue(BundleVariant.isBeta("com.LoganShire.Visor.Beta"))
        XCTAssertFalse(BundleVariant.isBeta("com.LoganShire.Visor"))
        XCTAssertFalse(BundleVariant.isBeta(".Beta"))
        XCTAssertEqual(BundleVariant.productionID("com.LoganShire.Visor.Beta"), "com.LoganShire.Visor")
        XCTAssertEqual(BundleVariant.productionID("com.LoganShire.Applications.Mac.Beta"), "com.LoganShire.Applications.Mac")
        XCTAssertEqual(BundleVariant.productionID("com.LoganShire.Visor"), "com.LoganShire.Visor")
        XCTAssertEqual(BundleVariant.productionName("Visor β", bundleID: "com.LoganShire.Visor.Beta"), "Visor")
        XCTAssertEqual(BundleVariant.productionName("Visor β", bundleID: "com.LoganShire.Visor"), "Visor β", "not a beta's id")
        XCTAssertEqual(BundleVariant.productionName("Visor", bundleID: "com.LoganShire.Visor.Beta"), "Visor")
        func build(_ bundleID: String, _ name: String) -> Build {
            Build(id: bundleID, bundleID: bundleID, name: name, version: "0.1", buildNumber: "1", published: Date(), size: 0)
        }
        let beta = build("com.LoganShire.Visor.Beta", "Visor β"), production = build("com.LoganShire.Visor", "Visor")
        XCTAssertEqual(beta.productionBundleID, production.bundleID)
        XCTAssertEqual(beta.identity, production.identity)
        XCTAssertEqual(beta.identity(["com.LoganShire.Visor": "Visor Isomer"]), "Visor Isomer", "named by the production's id")
        XCTAssertEqual(beta.identity(["com.LoganShire.Visor.Beta": "Blue"]), "Blue", "or its own")
    }
}
