import SwiftUI

/// Applications' settings: the server (connecting to it with its code,
/// where it is reached, this device's trust in it, forgetting it).
struct SettingsView: View {
    @Environment(ApplicationsStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if store.code != nil {
                    ServerSection(connection: store.connection, refreshing: store.isRefreshing, refresh: store.refresh, forget: store.forget)
                    if DeviceInstalls.needsTrustedAuthority { CertificateSection() }
                } else {
                    ConnectSection(connection: store.connection, command: "applications-server code", connect: store.connect)
                }
                AboutSection(shownVersion: store.showsFixture ? "1.0 (1)" : nil)
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: DeviceInstalls.sheetMinimumWidth, minHeight: DeviceInstalls.sheetMinimumHeight)
    }
}
