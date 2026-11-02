import CryptoKit
import Foundation
import PipelineClient
import Security
import Synchronization

/// The app's trust in its server, on Apple's systems: the chain must end in
/// the certificate authority the connection code names. And, on the side,
/// whether the system trusts that chain on its own: iOS installs over the
/// air only then, so installs wait for the authority's profile to be
/// installed and trusted.
final class ServerTrust: NSObject, URLSessionDelegate, ServerPinning, Sendable {
    let fingerprint: String
    /// The system's own verdict, from the last connection.
    private let verdict = Mutex<Bool?>(nil)

    init(fingerprint: String) { self.fingerprint = fingerprint }

    var systemTrusts: Bool? { verdict.withLock { $0 } }

    func session(_ configuration: URLSessionConfiguration) -> URLSession {
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let root = chain.last else {
            return (.cancelAuthenticationChallenge, nil)
        }
        // First as the system sees it (its anchors and the ones the user
        // installed and trusted), before the pin replaces the anchors.
        let system = SecTrustEvaluateWithError(trust, nil)
        verdict.withLock { $0 = system }
        let der = SecCertificateCopyData(root) as Data
        guard SHA256.hash(data: der).map({ String(format: "%02x", $0) }).joined() == fingerprint else {
            return (.cancelAuthenticationChallenge, nil)
        }
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
