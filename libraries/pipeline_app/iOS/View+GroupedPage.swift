import SwiftUI

extension View {
    /// A page of rounded groups, inset from the edges: what a form already
    /// is on iOS.
    func groupedPage() -> some View { formStyle(.grouped) }
}
