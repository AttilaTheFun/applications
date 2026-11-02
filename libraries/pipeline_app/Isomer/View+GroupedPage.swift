import SwiftUI

extension View {
    /// A page of rounded groups, inset from the edges: what a form is on a
    /// phone (Isomer's Form draws Material's inset groups on Android, the
    /// iPhone's on the web), as on the iPhone.
    func groupedPage() -> some View { formStyle(.grouped) }
}
