/// The device's network, watched for a change of path (home Wi-Fi left,
/// Tailscale turned on): not watched on Isomer's platforms. On Android
/// coming back to the app refreshes, and so chooses the path again; on the
/// web there is one path, the page's own server.
@MainActor
final class NetworkWatch {
    init(changed: @escaping @Sendable (_ shape: String, _ localNetworkDenied: Bool) -> Void) {}
}
