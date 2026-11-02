import Foundation
import PipelineServer
import XCTest
@testable import ApplicationsServer

/// The launchd service `applications-server install` writes: its plist
/// as made, never loaded here.
final class ServiceTests: XCTestCase {
    private func definition(_ agent: LaunchAgent) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: agent.definitionData(), format: nil) as? [String: Any])
    }

    /// The server's own binary, kept in its data folder, run with `serve`
    /// at login and whenever it exits, its output in its own log folder.
    func testTheServiceRunsTheServersOwnCopy() throws {
        let home = TestIPA.folder()
        let paths = ServerPaths(root: home.appendingPathComponent("Library/Application Support/Applications"))
        let agent = ServerService.agent(paths: paths, environment: [:], home: home)
        XCTAssertEqual(agent.plist.path, home.path + "/Library/LaunchAgents/com.LoganShire.ApplicationsServer.plist")
        let plist = try definition(agent)
        XCTAssertEqual(plist["Label"] as? String, "com.LoganShire.ApplicationsServer")
        XCTAssertEqual(plist["ProgramArguments"] as? [String],
                       [home.path + "/Library/Application Support/Applications/bin/applications-server", "serve"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["ThrottleInterval"] as? Int, 10)
        let log = home.path + "/Library/Logs/Applications Server/applications-server.log"
        XCTAssertEqual(plist["StandardOutPath"] as? String, log)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, log)
        XCTAssertNil(plist["EnvironmentVariables"])
        XCTAssertEqual(Set(plist.keys), ["Label", "ProgramArguments", "RunAtLoad", "KeepAlive", "ThrottleInterval", "StandardOutPath",
                                         "StandardErrorPath"])
        XCTAssertEqual(ServerService.commandLink(home: home).path, home.path + "/.local/bin/applications-server")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent.plist.path), "made, not written")
    }

    /// A data folder named by APPLICATIONS_DATA_DIR is the service's too:
    /// its binary is kept there, and launchd names it to `serve`.
    func testANamedDataFolderGoesWithTheService() throws {
        let home = TestIPA.folder()
        let scratch = home.appendingPathComponent("scratch")
        let agent = ServerService.agent(paths: ServerPaths(root: scratch), environment: ["APPLICATIONS_DATA_DIR": scratch.path], home: home)
        let plist = try definition(agent)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [scratch.path + "/bin/applications-server", "serve"])
        XCTAssertEqual(plist["EnvironmentVariables"] as? [String: String], ["APPLICATIONS_DATA_DIR": scratch.path])
    }
}
