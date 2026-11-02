import PipelineClient
import SwiftUI

/// The server connected to: its name, the path that answered, what went
/// wrong (with each path tried and why it did not answer, when none did),
/// and Refresh and Forget.
struct ServerSection: View {
    let connection: ServerConnection
    let refreshing: Bool
    let refresh: () async -> Void
    let forget: () -> Void
    @State private var forgetting = false

    var body: some View {
        Section(connection.serverName.prefix(1).uppercased() + connection.serverName.dropFirst()) {
            LabeledContent("Server", value: connection.code?.name ?? "")
            LabeledContent("Reached at", value: reachedAt)
            if let problem = connection.problem {
                Text(problem).foregroundStyle(.red)
                if connection.address == nil {
                    ForEach(triedPaths, id: \.address) { path in
                        LabeledContent(path.name, value: path.why)
                    }
                }
            } else if connection.localNetworkDenied, let address = connection.address, ServerClient.rank(address) == 2 {
                // Through the tailnet at home: the LAN is closed to this app.
                Text(connection.noLocalNetwork).font(.footnote).foregroundStyle(.orange)
            }
            Button("Refresh") { Task { await refresh() } }
                .disabled(refreshing)
            Button("Forget the Server", role: .destructive) { forgetting = true }
        }
        .confirmationDialog("Forget the \(connection.serverName)?", isPresented: $forgetting) {
            Button("Forget the Server", role: .destructive, action: forget)
        } message: {
            Text("Its connection code is deleted from this device; connecting again needs it.")
        }
    }

    /// The paths asked that did not answer, the LAN's first, and why
    /// (this device's own is left out: it answers only on the server's
    /// Mac, where it is the one that answers).
    private var triedPaths: [(address: String, name: String, why: String)] {
        connection.failures
            .filter { ServerClient.rank($0.key) > 0 }
            .sorted { (ServerClient.rank($0.key), $0.key) < (ServerClient.rank($1.key), $1.key) }
            .map { (address: $0.key, name: Self.name($0.key), why: $0.value) }
    }

    /// A path as Settings names it: its host, and which path it is.
    static func name(_ address: String) -> String {
        let host = URL(string: address)?.host() ?? address
        switch ServerClient.rank(address) {
        case 0: return "this Mac"
        case 1: return host + " (LAN)"
        default: return host + (ServerClient.isOverlay(address) ? " (tailnet)" : "")
        }
    }

    /// The address that answered, and which path it is.
    private var reachedAt: String {
        guard let address = connection.address else { return refreshing ? "Asking…" : "Not reached" }
        return Self.name(address)
    }
}
