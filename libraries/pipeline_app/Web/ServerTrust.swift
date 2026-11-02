import Foundation
import PipelineClient

/// The app's trust in its server, on the web: the browser's. The page is
/// served by the server, over its HTTPS, so the browser already trusts its
/// certificate (its authority installed on the device, or a proxy's real
/// certificate in front); every request goes to the page's own origin
/// (index.html's fetch), and the code's authority is not asked.
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
