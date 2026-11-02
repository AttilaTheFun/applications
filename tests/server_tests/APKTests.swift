import ApplicationsProtocol
import CryptoKit
import Foundation
import PipelineClient
import XCTest
@testable import ApplicationsServer

final class APKTests: XCTestCase {
    func testAnAPKSaysWhatItIs() throws {
        let folder = TestIPA.folder()
        let certificate = Data("the owner's debug key".utf8)
        let metadata = try IPAMetadata.read(try TestAPK.make(in: folder, certificate: certificate))
        XCTAssertEqual(metadata.platform, "android")
        XCTAssertEqual(metadata.bundleID, "com.example.visor")
        XCTAssertEqual(metadata.name, "Visor")
        XCTAssertEqual(metadata.version, "0.31")
        XCTAssertEqual(metadata.buildNumber, "31")
        XCTAssertEqual(metadata.icon, Data("icon-xxxhdpi".utf8))
        XCTAssertEqual(metadata.signer, SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined())
        XCTAssertNil(metadata.executableUUID)
    }

    /// An adaptive icon's XML is drawn by the launcher: the PNGs of its
    /// name stand for it.
    func testAnAdaptiveIconIsPicturedByItsPNGs() {
        let entries = ["res/mipmap-anydpi-v26/ic_launcher.xml", "res/mipmap-hdpi-v4/ic_launcher.png",
                       "res/mipmap-xxhdpi-v4/ic_launcher.png", "res/mipmap-xxhdpi-v4/ic_launcher_round.png"]
        XCTAssertEqual(IPAMetadata.iconEntry([("res/mipmap-anydpi-v26/ic_launcher.xml", 0xFFFE)], entries: entries),
                       "res/mipmap-xxhdpi-v4/ic_launcher.png")
        XCTAssertNil(IPAMetadata.iconEntry([("res/a.xml", 0xFFFE)], entries: ["res/a.xml"]))
    }

    func testAnUnsignedAPKIsRefused() throws {
        let folder = TestIPA.folder()
        let store = BuildStore(folder: folder.appendingPathComponent("builds"))
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.add(package: try TestAPK.make(in: folder, signed: false), notes: "")) { error in
            XCTAssertTrue(error is PackageCheck.Refusal, "\(error)")
            XCTAssertTrue("\(error)".contains("v2 or later"), "\(error)")
        }
        XCTAssertTrue(store.all().isEmpty)
    }

    func testAPKsArePublishedAsAndroidApps() throws {
        let folder = TestIPA.folder()
        let store = BuildStore(folder: folder.appendingPathComponent("builds"))
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let build = try store.add(package: try TestAPK.make(in: folder), notes: "First")
        XCTAssertEqual(build.platform, "android")
        XCTAssertEqual(build.versionTitle, "0.31 (31)")
        XCTAssertNotNil(build.signer)
        XCTAssertTrue(build.hasIcon)
        XCTAssertNil(build.buildScheme)
        XCTAssertEqual(store.package(build.id)?.lastPathComponent, "app.apk")
        XCTAssertEqual(store.apps(platform: "android").map(\.bundleID), ["com.example.visor"])
        XCTAssertTrue(store.apps(platform: "ios").isEmpty)
        XCTAssertEqual(store.fillIn(), 0)
        let listed = try WireCoding.decoder().decode(Build.self, from: WireCoding.encoder().encode(build))
        XCTAssertEqual(listed.signer, build.signer)
    }

    func testTheInboxTakesAPKs() {
        XCTAssertEqual(InboxPoller.waiting(in: ["applications.apk", "applications.md"]),
                       [InboxPoller.Waiting(build: "applications.apk", notes: "applications.md")])
    }
}
