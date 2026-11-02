import SwiftUI

/// Settings in the sidebar's toolbar, beside the sidebar's button (the
/// window's buttons are at the top left).
struct SettingsToolbar: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .primaryAction) { SettingsButton(action: action) }
        }
    }
}

extension View {
    func settingsToolbar(action: @escaping () -> Void) -> some View { modifier(SettingsToolbar(action: action)) }
}
