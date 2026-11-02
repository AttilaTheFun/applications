import Foundation

/// What asking every path to a server at once found: the best address
/// that answered, and why each that did not, did not — said in Settings,
/// so "can't be reached" comes with its reason (the LAN closed to this
/// app, the tailnet off, another server there).
public struct PathProbe: Sendable, Equatable {
    public var best: String?
    /// Each path that did not answer, and why, in words.
    public var failures: [String: String]

    public init(best: String? = nil, failures: [String: String] = [:]) {
        self.best = best
        self.failures = failures
    }

    /// What a LAN path says when the system refused this app the local
    /// network (Settings, Privacy & Security, Local Network).
    public static let localNetwork = "Local Network is off for this app"

    /// Some path failed because this app may not use the local network.
    public var localNetworkDenied: Bool { failures.values.contains(Self.localNetwork) }

    /// Words for why a path did not answer. The system says a refused
    /// local network only in the path it puts beside the error, an
    /// unsatisfied one "Local network prohibited".
    public static func why(_ error: any Error) -> String {
        let path = (error as NSError).userInfo["_NSURLErrorNWPathKey"].map { String(describing: $0) } ?? ""
        if path.localizedCaseInsensitiveContains("local network prohibited") { return localNetwork }
        guard let error = error as? URLError else { return "no answer" }
        switch error.code {
        case .cannotConnectToHost: return "refused"
        case .timedOut: return "no answer"
        case .notConnectedToInternet, .networkConnectionLost: return "no network"
        case .cannotFindHost, .dnsLookupFailed: return "name not found"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .secureConnectionFailed, .cancelled:
            return "not this server's certificate"
        default: return error.localizedDescription
        }
    }
}
