import Foundation
import FoundationNetworking
import PipelineClient

/// The app's trust in its server, on Linux and Windows: the system's. The
/// toolchain's URLSession (libcurl) checks a server against the system's
/// authorities alone, and lets an app add none of its own, so the computer
/// trusts the server's certificate authority, once (Settings says how), as
/// a browser must for an app on the web. The code's authority is not asked.
final class ServerTrust: ServerPinning {
    let fingerprint: String

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    var systemTrusts: Bool? { nil }

    func session(_ configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration)
    }
}
