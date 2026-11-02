import Foundation
// URLSession, on the toolchain's Foundation (Linux, Windows).
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How a platform reaches the server over HTTPS pinned to the certificate
/// authority its connection code names: the session requests go through,
/// and whether the system trusts that authority on its own (what installing
/// over the air needs on an iPhone; nil until a connection has said, or
/// where nothing asks).
public protocol ServerPinning: Sendable {
    var systemTrusts: Bool? { get }
    func session(_ configuration: URLSessionConfiguration) -> URLSession
}
