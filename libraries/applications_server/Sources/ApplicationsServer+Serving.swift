import Foundation
import PipelineHTTP
import PipelineServer

// Serving: the store brought up to date, the certificate readied
// for the computer's addresses, the plain port (the authority's profile)
// and the HTTPS port (everything) listened on, and the inbox watched. What
// `applications-server serve` runs, under its launchd service.
extension ApplicationsServer {
    /// The listeners, started; `failed` says why one stopped.
    public func serve(local: [LocalAddress], hostName: String, failed: @escaping @Sendable (String) -> Void) throws -> [HTTPListener] {
        let filled = builds.fillIn()
        if filled > 0 { FileHandle.standardError.write(Data("applications-server: read what was missing of \(filled) earlier builds\n".utf8)) }
        try prepareTLS(local: local, hostName: hostName)
        let handle: @Sendable (HTTPRequest) async -> HTTPResponse = { await self.handle($0) }
        let plain = try HTTPListener(port: config.httpPort, identity: nil, uploads: paths.uploads, uploadPath: Self.publishPath, handle: handle)
        let secure = try HTTPListener(port: config.httpsPort, identity: try tlsIdentity(), uploads: paths.uploads,
                                      uploadPath: Self.publishPath, handle: handle)
        for listener in [plain, secure] { listener.start(failed: failed) }
        if !config.inbox.isEmpty {
            if let inbox = InboxPoller(repository: config.inbox, scratch: paths.uploads) {
                Task.detached { await inbox.run { ipa, notes in _ = try await self.publish(package: ipa, notes: notes) } }
            } else {
                FileHandle.standardError.write(Data("applications-server: no gh here, so the inbox in \(config.inbox) is not watched\n".utf8))
            }
        }
        return [plain, secure]
    }
}
