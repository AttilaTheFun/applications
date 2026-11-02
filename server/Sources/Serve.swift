import ApplicationsServer
import Foundation
import PipelineServer

/// Running the server, as its launchd service does (`applications-server
/// install`): the plain port and the HTTPS port, until the computer's
/// addresses change, when it exits for launchd to start it again with a
/// certificate for them.
enum Serve {
    static func run(paths: ServerPaths, name: String, hostName: String) async throws {
        let server = try ApplicationsServer(paths: paths, name: name)
        let local = LocalAddress.current()
        _ = try await server.serve(local: local, hostName: hostName) { reason in
            FileHandle.standardError.write(Data("applications-server: a listener failed: \(reason)\n".utf8))
            exit(2)
        }
        let addresses = await server.addresses
        FileHandle.standardError.write(Data("applications-server \(ApplicationsServer.version) on \(addresses.joined(separator: ", "))\n".utf8))
        let issued = ServerAddressing.certificateNames(local, hostName: hostName)
        // Builds past their retention go at the start and every six hours,
        // not only when another is published.
        await server.pruneBuilds()
        var minutes = 0
        while true {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            minutes += 1
            if minutes % 360 == 0 { await server.pruneBuilds() }
            if ServerAddressing.certificateNames(LocalAddress.current(), hostName: hostName) != issued {
                FileHandle.standardError.write(Data("applications-server: the addresses changed; starting again\n".utf8))
                exit(0)
            }
        }
    }
}
