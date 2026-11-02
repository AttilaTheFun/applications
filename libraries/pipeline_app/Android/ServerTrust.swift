import Foundation
import PipelineClient
import PipelineHost

/// The app's trust in its server, on Android: the host pins HTTPS to the
/// certificate authority the connection code names, for the whole process
/// (a trust manager beside the system's, under every HttpsURLConnection,
/// Isomer's URLSession among them), so a session here is a plain one.
/// Nothing asks the system's own verdict (Android's installer is handed the
/// downloaded file): `systemTrusts` is nil.
final class ServerTrust: ServerPinning {
    let fingerprint: String

    init(fingerprint: String) {
        self.fingerprint = fingerprint
        // Made by the store, on the main actor, where the host is.
        MainActor.assumeIsolated { PipelineHostBox.current?.trustAuthority(fingerprint: fingerprint) }
    }

    var systemTrusts: Bool? { nil }

    func session(_ configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration)
    }
}
