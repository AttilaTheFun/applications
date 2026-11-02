import SwiftUI

/// Whether this device trusts the server's certificate authority,
/// which installing over the air needs, and how to.
struct CertificateSection: View {
    @Environment(ApplicationsStore.self) private var store
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            switch store.systemTrusts {
            case true?:
                Label("Trusted: builds install from this server.", systemImage: "checkmark.seal")
            case false?:
                Text("Installs need this device to trust the server's certificate authority, once:")
                Text("1. Get the profile (it opens in Safari, then Allow).\n2. Settings → General → VPN & Device Management: install the profile (named Applications).\n3. Settings → General → About → Certificate Trust Settings: turn on the server's certificate authority.")
                    .font(.footnote)
            case nil:
                Text("Checked when the server is reached.").foregroundStyle(.secondary)
            }
            Button("Get the Profile") { if let url = store.profileURL { openURL(url) } }
                .disabled(store.profileURL == nil)
        } header: {
            Text("Certificate")
        }
    }
}
