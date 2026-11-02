import Foundation
import PipelineServer

/// Applications Server as a launchd service of its own (`applications-server
/// install`): the binary kept in its data folder (bin/applications-server),
/// where a rebuilt checkout does not move it, run with `serve` at login and
/// whenever it exits, its output in ~/Library/Logs/Applications Server/.
public enum ServerService {
    public static let label = "com.LoganShire.ApplicationsServer"
    public static let command = "applications-server"

    /// The service for the server whose data `paths` names. A data folder
    /// named by APPLICATIONS_DATA_DIR is named to the service too, so it
    /// serves the folder it was installed for.
    public static func agent(paths: ServerPaths, environment: [String: String] = ProcessInfo.processInfo.environment,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser) -> LaunchAgent {
        let named = environment["APPLICATIONS_DATA_DIR"].map { !$0.isEmpty } ?? false
        return LaunchAgent(label: label, binary: paths.binary, log: log(home: home),
                           environment: named ? ["APPLICATIONS_DATA_DIR": paths.root.standardizedFileURL.path] : [:], home: home)
    }

    public static func log(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Logs/Applications Server/\(command).log")
    }

    /// The command on the PATH, ~/.local/bin/applications-server: a link to
    /// the service's binary, so the commands are the build that serves.
    public static func commandLink(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/bin/\(command)")
    }
}
