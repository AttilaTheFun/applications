import CryptoKit
import Foundation
import Security

/// A client's trust in one server: the chain it presents must end in the
/// certificate authority with this fingerprint, which is then its only
/// anchor. What `applications-server publish` uses to reach a server, here or
/// on another computer, without the authority installed system-wide.
public final class PinnedTrust: NSObject, URLSessionDelegate, Sendable {
    public let fingerprint: String

    public init(fingerprint: String) { self.fingerprint = fingerprint }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust, Self.pinned(trust, fingerprint: fingerprint) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// Whether `trust`'s chain ends in the authority with `fingerprint`,
    /// and holds with that authority as its only anchor.
    public static func pinned(_ trust: SecTrust, fingerprint: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let root = chain.last else { return false }
        let der = SecCertificateCopyData(root) as Data
        guard SHA256.hash(data: der).map({ String(format: "%02x", $0) }).joined() == fingerprint else { return false }
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
    }
}
