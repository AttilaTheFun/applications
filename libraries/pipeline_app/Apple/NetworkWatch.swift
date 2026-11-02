import Foundation
import Network

/// The device's network, watched on Apple's systems: each change (home
/// Wi-Fi left, Tailscale turned on) said by its shape, with whether the
/// system refused this app the local network.
@MainActor
final class NetworkWatch {
    private let monitor = NWPathMonitor()

    init(changed: @escaping @Sendable (_ shape: String, _ localNetworkDenied: Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            let shape = "\(path.status) " + path.availableInterfaces.map { "\($0.type)\($0.name)" }.joined(separator: ",")
            changed(shape, path.unsatisfiedReason == .localNetworkDenied)
        }
        monitor.start(queue: DispatchQueue(label: "applications.network"))
    }
}
