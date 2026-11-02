import SwiftUI

/// The toolbar's way to the app's settings: its server.
struct SettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Settings", systemImage: "gearshape")
        }
    }
}
