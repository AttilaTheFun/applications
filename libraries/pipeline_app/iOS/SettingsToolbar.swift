import SwiftUI
import UIKit

/// Settings in the list's toolbar: at the top left on a phone, beside the
/// sidebar's button on an iPad (whose window's buttons are at the top left;
/// its sidebar column says it is compact, so the device decides).
struct SettingsToolbar: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: UIDevice.current.userInterfaceIdiom == .pad ? .topBarTrailing : .topBarLeading) {
                SettingsButton(action: action)
            }
        }
    }
}

extension View {
    func settingsToolbar(action: @escaping () -> Void) -> some View { modifier(SettingsToolbar(action: action)) }
}
