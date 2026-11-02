import Foundation
import PipelineClient
import PipelineServer
import XCTest
@testable import ApplicationsProtocol
@testable import ApplicationsServer

final class ProtocolTests: XCTestCase {
    func testConnectionCodeRoundTrips() throws {
        let code = ConnectionCode(id: "s1", name: "Example Mac", addresses: ["https://192.0.2.52:7461", "https://100.64.0.11:7461"],
                                  password: "sample-words-only-1234", ca: String(repeating: "ab", count: 32))
        XCTAssertEqual(ConnectionCode(parsing: "  " + code.text + "\n"), code)
        XCTAssertFalse(code.text.contains("+") || code.text.contains("/") || code.text.contains("="))
        XCTAssertNil(ConnectionCode(parsing: "not a code"))
    }

    func testTheManifestNamesTheIPAAndTheApp() throws {
        let data = InstallManifest.plist(ipaURL: "https://192.0.2.52:7461/builds/b1/k/app.ipa", bundleID: "com.example.Visor",
                                         version: "0.23", title: "Visor")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let item = try XCTUnwrap((plist["items"] as? [[String: Any]])?.first)
        XCTAssertEqual((item["assets"] as? [[String: String]])?.first?["url"], "https://192.0.2.52:7461/builds/b1/k/app.ipa")
        XCTAssertEqual((item["metadata"] as? [String: String])?["bundle-identifier"], "com.example.Visor")
        let link = InstallManifest.installLink(manifestURL: "https://192.0.2.52:7461/builds/b1/k/manifest.plist")
        XCTAssertEqual(link, "itms-services://?action=download-manifest&url=https%3A%2F%2F192.0.2.52%3A7461%2Fbuilds%2Fb1%2Fk%2Fmanifest.plist")
    }

    func testDownloadKeysAreTheBuildsAndThePasswords() {
        let key = DownloadKey.make(password: "pw", build: "b1")
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(key, DownloadKey.make(password: "pw", build: "b1"))
        XCTAssertNotEqual(key, DownloadKey.make(password: "pw", build: "b2"))
        XCTAssertNotEqual(key, DownloadKey.make(password: "other", build: "b1"))
        XCTAssertTrue(DownloadKey.matches(key, password: "pw", build: "b1"))
        XCTAssertFalse(DownloadKey.matches("guess", password: "pw", build: "b1"))
    }

    func testOverlayAddressesAreTheTailnetRange() {
        XCTAssertTrue(LocalAddress.isOverlay("100.64.0.11"))
        XCTAssertTrue(LocalAddress.isOverlay("100.64.0.1"))
        XCTAssertFalse(LocalAddress.isOverlay("100.128.0.1"))
        XCTAssertFalse(LocalAddress.isOverlay("192.0.2.52"))
    }

    /// The paths in the order they are preferred: this computer itself,
    /// then the LAN, then the tailnet or the internet; and this computer's
    /// own address is asked too, at the server's port.
    func testPathsArePreferredThisComputerThenTheLANThenTheTailnet() {
        XCTAssertEqual(ServerClient.rank("https://127.0.0.1:7461"), 0)
        XCTAssertEqual(ServerClient.rank("https://10.0.0.49:7461"), 1)
        XCTAssertEqual(ServerClient.rank("https://10.0.0.2:7461"), 1)
        XCTAssertEqual(ServerClient.rank("https://example-mac.local:7461"), 1)
        XCTAssertEqual(ServerClient.rank("https://100.64.0.11:7461"), 2)
        XCTAssertEqual(ServerClient.rank("https://applications.example.com"), 2)
        XCTAssertEqual(ServerClient.candidates(["https://10.0.0.49:7461", "https://100.64.0.11:7461"]),
                       ["https://127.0.0.1:7461", "https://10.0.0.49:7461", "https://100.64.0.11:7461"])
    }

    /// "alpha", as beta was named, reads as beta in channels.json too (the
    /// protocol's own: //libraries/applications_protocol/tests).
    func testAlphaReadsAsBetaInChannels() throws {
        let entries = try JSONDecoder().decode([String: ChannelStore.Entry].self, from: Data(#"{"Visor\u001f0.35":{"channel":"alpha"}}"#.utf8))
        XCTAssertEqual(entries[ChannelStore.key("Visor", "0.35")]?.channel, .beta)
    }

    /// A build kept before builds had a channel of their own is its
    /// version's, as channels.json kept it; a build's own channel wins, and
    /// a version channels.json doesn't name is beta.
    func testABuildWithoutAChannelIsItsVersions() throws {
        let file = TestIPA.folder().appendingPathComponent("channels.json")
        try Data(#"{"Visor\u001f0.35":{"channel":"production"},"Visor\u001f0.36":{"channel":"alpha"}}"#.utf8).write(to: file)
        let channels = ChannelStore(file: file).snapshot(names: [:])
        func build(_ version: String, _ channel: ReleaseChannel? = nil) -> Build {
            Build(id: version, bundleID: "com.example.Visor", name: "Visor", version: version, buildNumber: "1",
                  published: Date(timeIntervalSince1970: 0), size: 1, channel: channel)
        }
        XCTAssertEqual(channels.channel(of: build("0.35")), .production)
        XCTAssertEqual(channels.channel(of: build("0.36")), .beta)
        XCTAssertEqual(channels.channel(of: build("0.37")), .beta)
        XCTAssertEqual(channels.channel(of: build("0.35", .beta)), .beta)
    }

    /// A build's push names the category whose action installs it.
    func testABuildsPushOffersInstall() throws {
        let device = DeviceRegistration(token: "abc", environment: "sandbox", topic: "com.example.Applications", name: "iPhone")
        let request = try XCTUnwrap(PushSender.request(to: device, jwt: "j", title: "t", body: "b", category: ApplicationsServer.buildCategory,
                                                       data: ["build": "b1"]))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual((payload["aps"] as? [String: Any])?["category"] as? String, "BUILD")
        XCTAssertEqual(payload["build"] as? String, "b1")
    }
}
