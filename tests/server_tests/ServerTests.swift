import ApplicationsProtocol
import Foundation
import Network
import PipelineClient
import PipelineHTTP
import PipelineServer
import XCTest
@testable import ApplicationsServer

final class ServerTests: XCTestCase {
    private func makeServer() async throws -> (ApplicationsServer, URL) {
        let folder = TestIPA.folder()
        let server = try ApplicationsServer(paths: ServerPaths(root: folder.appendingPathComponent("support")), name: "Test Mac")
        try await server.prepareTLS(local: [LocalAddress(ip: "192.0.2.52", overlay: false), LocalAddress(ip: "100.64.0.11", overlay: true)],
                                    hostName: "test-mac.local")
        return (server, folder)
    }

    private func bearer(_ server: ApplicationsServer) async -> [String: String] {
        ["authorization": "Bearer " + (await server.config.password)]
    }

    func testThePlainPortAnswersOnlyWhatComesBeforeTrust() async throws {
        let (server, _) = try await makeServer()
        let hello = await server.handle(HTTPRequest(method: "GET", path: "/api/hello", secure: false))
        XCTAssertEqual(hello.status, 200)
        let said = try WireCoding.decoder().decode(Hello.self, from: hello.data)
        // The LAN's, then the computer's .local name (which finds it at home
        // whatever address its router gives it next), then the tailnet's.
        XCTAssertEqual(said.addresses, ["https://192.0.2.52:7461", "https://test-mac.local:7461", "https://100.64.0.11:7461"])
        let profile = await server.handle(HTTPRequest(method: "GET", path: "/ca.mobileconfig", secure: false))
        XCTAssertEqual(profile.status, 200)
        XCTAssertEqual(profile.headers["Content-Type"], "application/x-apple-aspen-config")
        let apps = await server.handle(HTTPRequest(method: "GET", path: "/api/apps", headers: await bearer(server), secure: false))
        XCTAssertEqual(apps.status, 404)
    }

    func testTheAPIWantsThePasswordAndPublishingFromHereDoesNot() async throws {
        let (server, folder) = try await makeServer()
        let refused = await server.handle(HTTPRequest(method: "GET", path: "/api/apps"))
        XCTAssertEqual(refused.status, 401)
        let remote = await server.handle(HTTPRequest(method: "POST", path: "/api/publish", bodyFile: try TestIPA.make(in: folder)))
        XCTAssertEqual(remote.status, 401)
        let notes = Data("Dictation\nand more".utf8).base64EncodedString()
        let published = await server.handle(HTTPRequest(method: "POST", path: "/api/publish", headers: ["x-applications-notes": notes],
                                                        bodyFile: try TestIPA.make(in: folder), local: true))
        XCTAssertEqual(published.status, 201)
        let build = try WireCoding.decoder().decode(Build.self, from: published.data)
        XCTAssertEqual(build.notes, "Dictation\nand more")
        XCTAssertEqual(build.downloadKey.count, 32)

        let apps = await server.handle(HTTPRequest(method: "GET", path: "/api/apps", headers: await bearer(server)))
        XCTAssertEqual(apps.status, 200)
        XCTAssertEqual(try WireCoding.decoder().decode([AppBuilds].self, from: apps.data).first?.latest?.id, build.id)

        // The install links: the key is the permission.
        let manifest = await server.handle(HTTPRequest(method: "GET", path: "/builds/\(build.id)/\(build.downloadKey)/manifest.plist",
                                                       headers: ["host": "100.64.0.11:7461"]))
        XCTAssertEqual(manifest.status, 200)
        XCTAssertTrue(String(decoding: manifest.data, as: UTF8.self)
            .contains("https://100.64.0.11:7461/builds/\(build.id)/\(build.downloadKey)/app.ipa"))
        let ipa = await server.handle(HTTPRequest(method: "GET", path: "/builds/\(build.id)/\(build.downloadKey)/app.ipa"))
        XCTAssertEqual(ipa.status, 200)
        guard case .file(_, let size) = ipa.body else { return XCTFail("the .ipa is sent from its file") }
        XCTAssertEqual(size, build.size)
        let guessed = await server.handle(HTTPRequest(method: "GET", path: "/builds/\(build.id)/0000/manifest.plist"))
        XCTAssertEqual(guessed.status, 404)
    }

    func testAnAPKIsListedForAndroidAndDownloadedAsOne() async throws {
        let (server, folder) = try await makeServer()
        let published = await server.handle(HTTPRequest(method: "POST", path: "/api/publish", bodyFile: try TestAPK.make(in: folder),
                                                        local: true))
        XCTAssertEqual(published.status, 201)
        let build = try WireCoding.decoder().decode(Build.self, from: published.data)
        XCTAssertEqual(build.platform, "android")
        let apps = await server.handle(HTTPRequest(method: "GET", path: "/api/apps", query: ["platform": "android"], headers: await bearer(server)))
        XCTAssertEqual(try WireCoding.decoder().decode([AppBuilds].self, from: apps.data).first?.latest?.id, build.id)
        let phones = await server.handle(HTTPRequest(method: "GET", path: "/api/apps", headers: await bearer(server)))
        XCTAssertEqual(try WireCoding.decoder().decode([AppBuilds].self, from: phones.data).count, 0)
        let apk = await server.handle(HTTPRequest(method: "GET", path: "/builds/\(build.id)/\(build.downloadKey)/app.apk"))
        XCTAssertEqual(apk.status, 200)
        XCTAssertEqual(apk.headers["Content-Type"], "application/vnd.android.package-archive")
        let asIPA = await server.handle(HTTPRequest(method: "GET", path: "/builds/\(build.id)/\(build.downloadKey)/app.ipa"))
        XCTAssertEqual(asIPA.status, 404)
        let icon = await server.handle(HTTPRequest(method: "GET", path: "/api/builds/\(build.id)/icon", headers: await bearer(server)))
        XCTAssertEqual(icon.data, Data("icon-xxxhdpi".utf8))
    }

    func testADeviceRegistersWithItsToken() async throws {
        let (server, _) = try await makeServer()
        let device = DeviceRegistration(token: "a1b2c3", environment: "sandbox", topic: "com.LoganShire.Applications", name: "iPhone")
        let body = try JSONEncoder().encode(device)
        let answer = await server.handle(HTTPRequest(method: "POST", path: "/api/devices", headers: await bearer(server), body: body))
        XCTAssertEqual(answer.status, 200)
        let first = await server.devices.all()
        XCTAssertEqual(first, [device])
        // Again, with a new token (the app installed again): one entry.
        var again = device
        again.token = "d4e5f6"
        _ = await server.handle(HTTPRequest(method: "POST", path: "/api/devices", headers: await bearer(server),
                                            body: try JSONEncoder().encode(again)))
        let second = await server.devices.all()
        XCTAssertEqual(second, [again])
    }

    func testTheCertificateCoversTheAddressesAndIsIssuedAgainWhenTheyChange() async throws {
        let (server, folder) = try await makeServer()
        let names = await server.issuedNames()
        XCTAssertEqual(names, ["192.0.2.52", "100.64.0.11", "127.0.0.1", "localhost", "test-mac.local"])
        let authority = CertificateAuthority(folder: folder.appendingPathComponent("support/tls"), name: "Applications")
        XCTAssertFalse(try authority.ensure(names: names, title: "Test Mac"))
        XCTAssertTrue(try authority.ensure(names: ["192.0.2.60", "127.0.0.1"], title: "Test Mac"))
        XCTAssertEqual(try authority.fingerprint().count, 64)
        _ = try authority.identity()
        let code = try await server.connectionCode()
        XCTAssertEqual(code.ca, try authority.fingerprint())
    }

    /// The profile a device installs to trust the authority is named for
    /// the app, Applications; its identifiers are the server's, so a device
    /// that installs it again replaces the one it has.
    func testTheCertificateProfileIsNamedForApplications() async throws {
        let (_, folder) = try await makeServer()
        let authority = CertificateAuthority(folder: folder.appendingPathComponent("support/tls"), name: "Applications")
        let data = try authority.profile(serverID: "s1", title: "Test Mac", purpose: "Lets this device install builds.")
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(profile["PayloadDisplayName"] as? String, "Applications (Test Mac)")
        XCTAssertEqual(profile["PayloadIdentifier"] as? String, "applications.s1")
        let payload = try XCTUnwrap((profile["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["PayloadDisplayName"] as? String, "Applications CA")
    }

    /// The HTTPS port for real: the listener's TLS, with the authority's
    /// certificate sent in the chain, trusted by a client that pins it.
    func testHTTPSAnswersAClientThatTrustsTheAuthority() async throws {
        let (server, folder) = try await makeServer()
        // A port the system chooses: tests on OS Server's Mac slots share
        // the primary's loopback, and a fixed or random one may be taken.
        let port = try freePort()
        let listener = try HTTPListener(port: port, identity: try server.tlsIdentity(), uploads: folder, uploadPath: ApplicationsServer.publishPath,
                                        handle: { await server.handle($0) })
        listener.start { XCTFail("the listener failed: \($0)") }
        defer { listener.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        let pinning = PinnedTrust(fingerprint: try await server.connectionCode().ca)
        let session = URLSession(configuration: .ephemeral, delegate: pinning, delegateQueue: nil)
        let (data, response) = try await session.data(from: try XCTUnwrap(URL(string: "https://127.0.0.1:\(port)/api/hello")))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try WireCoding.decoder().decode(Hello.self, from: data).name, "Test Mac")
    }

    /// A free TCP port on the loopback, which the system chose: bound to
    /// port 0, read back, and closed for the listener to take.
    private func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // Darwin's: inside an XCTestCase, `bind` is NSObject's.
                Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return UInt16(bigEndian: address.sin_port)
    }
}
