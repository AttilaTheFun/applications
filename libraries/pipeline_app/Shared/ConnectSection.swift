import SwiftUI

/// The server's connection code, pasted (what its `code` command prints on
/// the server's Mac); its link, or the QR code of it, connects at once.
struct ConnectSection: View {
    let connection: ServerConnection
    /// The command on the server's Mac that prints the code ("applications-server code").
    let command: String
    /// Connects with the code, and asks the server: nil, or why not.
    let connect: (String) async -> String?
    @State private var text = ""
    @State private var problem: String?
    @State private var connecting = false

    var body: some View {
        Section {
            TextField("Connection code", text: $text, axis: .vertical)
                .lineLimit(3...6)
                .autocorrectionDisabled()
                .font(.callout.monospaced())
            Button(connecting ? "Connecting…" : "Connect") {
                connecting = true
                Task {
                    problem = await connect(text)
                    connecting = false
                }
            }
            .disabled(text.isEmpty || connecting)
            if let problem = problem ?? connection.problem {
                Text(problem).foregroundStyle(.red)
            }
        } header: {
            Text(connection.serverName.prefix(1).uppercased() + connection.serverName.dropFirst())
        } footer: {
            Text("The code `\(command)` prints on the server's Mac: its addresses, its password and its certificate. Or open the link (`--link`) or scan the QR code (`--qr`) it makes.")
        }
    }
}
