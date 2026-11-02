import ApplicationsProtocol
import Foundation
import PipelineClient
import PipelineServer
import XCTest
@testable import ApplicationsServer

final class BuildStoreTests: XCTestCase {
    func testAnIPASaysWhatItIs() throws {
        let folder = TestIPA.folder()
        let metadata = try IPAMetadata.read(try TestIPA.make(in: folder))
        XCTAssertEqual(metadata.bundleID, "com.example.Visor")
        XCTAssertEqual(metadata.name, "Visor")
        XCTAssertEqual(metadata.version, "0.23")
        XCTAssertEqual(metadata.buildNumber, "23")
        XCTAssertEqual(metadata.icon, Data("icon-3x".utf8))
        XCTAssertEqual(metadata.executableUUID, MachOUUID.uuid(ofFileAt: URL(fileURLWithPath: "/usr/bin/true")))
        XCTAssertNotNil(metadata.executableUUID)
    }

    /// The UUID read from an executable's bytes and from its file is the
    /// one the toolchain says (the arm64 slice of a universal binary).
    func testAnExecutablesUUIDIsTheLinkersOwn() throws {
        let file = URL(fileURLWithPath: "/usr/bin/true")
        let said = String(decoding: try ProcessRunner.run("/usr/bin/dwarfdump", ["--uuid", "--arch", "arm64e", file.path]), as: UTF8.self)
        let uuid = try XCTUnwrap(MachOUUID.uuid(ofFileAt: file))
        XCTAssertTrue(said.contains(uuid), "\(said) has \(uuid)")
        XCTAssertEqual(MachOUUID.uuid(in: try Data(contentsOf: file)), uuid)
        XCTAssertNil(MachOUUID.uuid(in: Data("not an executable".utf8)))
    }

    func testBuildsAreKeptByAppNewestFirst() throws {
        let folder = TestIPA.folder()
        let store = BuildStore(folder: folder.appendingPathComponent("builds"))
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<12 {
            _ = try store.add(package: try TestIPA.make(in: folder, build: String(index)), notes: "build \(index)",
                              now: start.addingTimeInterval(Double(index)))
        }
        let other = try store.add(package: try TestIPA.make(in: folder, bundleID: "com.example.Overcast", name: "Overcast"), notes: "",
                                  now: start.addingTimeInterval(100))
        let apps = store.apps()
        XCTAssertEqual(apps.map(\.name), ["Overcast", "Visor"])
        XCTAssertEqual(apps[1].builds.count, 12, "all within the week (RetentionTests: what goes after it)")
        XCTAssertEqual(apps[1].builds.first?.buildNumber, "11")
        XCTAssertEqual(apps[1].builds.last?.buildNumber, "0")
        XCTAssertEqual(store.build(other.id)?.name, "Overcast")
        XCTAssertNotNil(store.package(other.id))
        XCTAssertEqual(store.icon(other.id), Data("icon-3x".utf8))
        XCTAssertNil(store.build("../config.json"))
    }

    /// A build published before UUIDs were read gets its own from its .ipa.
    func testEarlierBuildsGetTheirExecutablesUUID() throws {
        let folder = TestIPA.folder()
        let store = BuildStore(folder: folder.appendingPathComponent("builds"))
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        var build = try store.add(package: try TestIPA.make(in: folder), notes: "")
        let uuid = build.executableUUID
        XCTAssertNotNil(uuid)
        build.executableUUID = nil
        build.urlSchemes = nil
        try WireCoding.encoder().encode(build).write(to: store.folder.appendingPathComponent(build.id).appendingPathComponent("build.json"))
        XCTAssertNil(store.build(build.id)?.executableUUID)
        XCTAssertEqual(store.fillIn(), 1)
        XCTAssertEqual(store.build(build.id)?.executableUUID, uuid)
        XCTAssertEqual(store.build(build.id)?.urlSchemes, ["testapp"])
        XCTAssertEqual(store.fillIn(), 0)
    }

    /// The inbox's builds, each with the notes named after it.
    func testTheInboxPairsBuildsWithTheirNotes() {
        let waiting = InboxPoller.waiting(in: ["visor-0.24.md", "visor-0.24.ipa", "playground.ipa", "stray.md"])
        XCTAssertEqual(waiting, [InboxPoller.Waiting(build: "playground.ipa", notes: nil),
                                 InboxPoller.Waiting(build: "visor-0.24.ipa", notes: "visor-0.24.md")])
    }

    /// A config from before a setting reads with its default, keeping its
    /// password.
    func testAnEarlierConfigKeepsItsPassword() throws {
        let earlier = Data(#"{"id":"s1","name":"Server","password":"amber-birch-cedar-1234","apnsKeyID":"","apnsTeamID":""}"#.utf8)
        let config = try JSONDecoder().decode(ServerConfig.self, from: earlier)
        XCTAssertEqual(config.password, "amber-birch-cedar-1234")
        XCTAssertEqual(config.inbox, "")
        XCTAssertEqual([config.httpPort, config.httpsPort], [7460, 7461])
    }

    /// A setting the server no longer has is read past, and goes when the
    /// config is kept again.
    func testASettingNoLongerKeptIsReadPast() throws {
        let file = TestIPA.folder().appendingPathComponent("config.json")
        try Data(#"{"id":"s1","name":"Example Mac","password":"pw","inbox":"owner/repo","requirePassword":false,"retired":"a value"}"#.utf8).write(to: file)
        let config = try ServerConfig.loadOrCreate(at: file, name: "Other")
        XCTAssertEqual(config.password, "pw", "read, not made again")
        XCTAssertEqual(config.inbox, "owner/repo")
        XCTAssertFalse(config.requirePassword)
        try config.save(to: file)
        let kept = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(kept["retired"])
        XCTAssertEqual(kept["password"] as? String, "pw")
    }

    /// The ports are 7460 and 7461 by default; a config's own ports stay.
    func testThePortsAre7460And7461() throws {
        let made = try ServerConfig.loadOrCreate(at: TestIPA.folder().appendingPathComponent("config.json"), name: "Server")
        XCTAssertEqual([made.httpPort, made.httpsPort], [7460, 7461])
        let other = Data(#"{"id":"s1","name":"Server","password":"pw","httpPort":8080,"httpsPort":8443}"#.utf8)
        let kept = try JSONDecoder().decode(ServerConfig.self, from: other)
        XCTAssertEqual([kept.httpPort, kept.httpsPort], [8080, 8443])
        XCTAssertEqual(ServerClient.profileURL(for: "https://192.0.2.52:7461")?.absoluteString, "http://192.0.2.52:7460/")
    }

    /// A Mac app's .zip and disk image: read as the Mac's, kept as a
    /// .zip, its icon a PNG, listed apart from the iPhone's.
    func testMacAppsArePublishedAsZips() throws {
        let folder = TestIPA.folder()
        let store = BuildStore(folder: folder.appendingPathComponent("builds"))
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let zipped = try store.add(package: try TestMacApp.make(in: folder), notes: "")
        XCTAssertEqual(zipped.platform, "macos")
        XCTAssertEqual(zipped.bundleID, "com.example.VisorMac")
        XCTAssertEqual(zipped.versionTitle, "0.24 (24)")
        XCTAssertTrue(zipped.hasIcon)
        XCTAssertEqual(store.icon(zipped.id)?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "a PNG")
        XCTAssertEqual(zipped.executableUUID, MachOUUID.uuid(ofFileAt: URL(fileURLWithPath: "/usr/bin/true")))
        XCTAssertEqual(store.package(zipped.id)?.lastPathComponent, "app.zip")
        let imaged = try store.add(package: try TestMacApp.make(in: folder, build: "25", diskImage: true), notes: "",
                                   now: Date().addingTimeInterval(1))
        XCTAssertEqual(imaged.platform, "macos")
        XCTAssertEqual(imaged.buildNumber, "25")
        XCTAssertEqual(store.package(imaged.id)?.lastPathComponent, "app.zip")
        _ = try store.add(package: try TestIPA.make(in: folder), notes: "")
        XCTAssertEqual(store.apps(platform: "macos").map(\.bundleID), ["com.example.VisorMac"])
        XCTAssertEqual(store.apps(platform: "macos").first?.builds.count, 2)
        XCTAssertEqual(store.apps(platform: "ios").map(\.bundleID), ["com.example.Visor"])
    }

    /// An .ipa with AppleDouble files in its app is published without them;
    /// a build whose signature does not verify is refused.
    func testABuildTheDeviceWouldRefuseIsFixedOrRefused() throws {
        let folder = TestIPA.folder()
        let store = BuildStore(folder: folder.appendingPathComponent("builds"))
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let doubled = try TestIPA.make(in: folder, appleDouble: true)
        XCTAssertTrue(String(decoding: try ProcessRunner.run("/usr/bin/unzip", ["-Z1", doubled.path]), as: UTF8.self).contains("._Info.plist"))
        let build = try store.add(package: doubled, notes: "")
        let kept = String(decoding: try ProcessRunner.run("/usr/bin/unzip", ["-Z1", try XCTUnwrap(store.package(build.id)).path]), as: UTF8.self)
        XCTAssertFalse(kept.contains("._"))
        XCTAssertThrowsError(try store.add(package: try TestMacApp.make(in: folder, signed: false), notes: "")) { error in
            XCTAssertTrue("\(error)".contains("signature"), "\(error)")
        }
        XCTAssertEqual(store.apps(platform: "macos"), [])
    }

    /// An iPhone app signed with a wildcard profile's entitlements as they
    /// are ("<team>.*") is refused: iOS would not install it. Signed as
    /// itself, it is published.
    func testAnAppSignedAsTheWildcardIsRefused() throws {
        let folder = TestIPA.folder()
        let store = BuildStore(folder: folder.appendingPathComponent("builds"))
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.add(package: try TestIPA.make(in: folder, applicationIdentifier: "ABCDE12345.*"), notes: "")) { error in
            XCTAssertTrue("\(error)".contains("application-identifier <team>.com.example.Visor"), "\(error)")
            XCTAssertFalse("\(error)".contains("ABCDE12345"), "the team stays out of it")
        }
        XCTAssertEqual(store.apps(platform: "ios"), [])
        XCTAssertNoThrow(try store.add(package: try TestIPA.make(in: folder, applicationIdentifier: "ABCDE12345.com.example.Visor"), notes: ""))
        XCTAssertEqual(store.apps(platform: "ios").map(\.bundleID), ["com.example.Visor"])
    }
}
