import Foundation
import PipelineClient
import PipelineServer

/// Whether the server's ports answer on this Mac, and as this server: its
/// hello, on the plain port and on HTTPS pinned to its own authority, with
/// its own id. Another server on a port answers as itself, or not with
/// this server's certificate, and is named so.
enum ServicePorts {
    static func answers(http: UInt16, https: UInt16, id: String, fingerprint: String) async -> String {
        async let plain = answer(port: http, secure: false, id: id, fingerprint: fingerprint)
        async let secure = answer(port: https, secure: true, id: id, fingerprint: fingerprint)
        return "HTTP \(http) \(await plain); HTTPS \(https) \(await secure)"
    }

    private static func answer(port: UInt16, secure: Bool, id: String, fingerprint: String) async -> String {
        guard let url = URL(string: "\(secure ? "https" : "http")://127.0.0.1:\(port)/api/hello") else { return "is not a port" }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = secure ? URLSession(configuration: configuration, delegate: PinnedTrust(fingerprint: fingerprint), delegateQueue: nil)
            : URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, _) = try await session.data(from: url)
            guard let hello = try? WireCoding.decoder().decode(Hello.self, from: data) else { return "answers, but not as a server of ours" }
            return hello.id == id ? "answers" : "answers as another server (\(hello.name), \(hello.kind ?? "unnamed"))"
        } catch let error as URLError where error.code == .cancelled {
            return "answers, but not with this server's certificate"
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return "does not answer"
        } catch {
            return "does not answer (\(error.localizedDescription))"
        }
    }
}
