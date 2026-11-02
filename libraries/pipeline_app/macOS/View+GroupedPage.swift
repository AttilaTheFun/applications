import SwiftUI

extension View {
    /// A page of rounded groups, as Visor's Computer Settings is: the Mac's
    /// grouped form, its cells kept to a readable width in a wide window.
    /// The form itself takes the whole column, so its scroll edge (the bar
    /// under the toolbar) runs edge to edge; the width is in its margins.
    func groupedPage() -> some View { modifier(GroupedPage()) }
}

/// The grouped form across the column, its content centred at `width`.
private struct GroupedPage: ViewModifier {
    /// The content's width, the form's own insets included.
    static let width: CGFloat = 560

    @State private var column: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .contentMargins(.horizontal, max(0, (column - Self.width) / 2), for: .scrollContent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { column = $0 }
    }
}
