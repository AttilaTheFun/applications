import SwiftUI

/// Settings in the list's toolbar, as the iPhone and iPad have it: at the
/// top left in one column (a phone), beside the sidebar's own buttons
/// otherwise (a tablet, a window two columns wide).
struct SettingsToolbar: ViewModifier {
    let action: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: sizeClass == .compact ? .topBarLeading : .topBarTrailing) {
                SettingsButton(action: action)
            }
        }
    }
}

extension View {
    func settingsToolbar(action: @escaping () -> Void) -> some View { modifier(SettingsToolbar(action: action)) }
}
