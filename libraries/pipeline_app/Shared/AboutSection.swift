import SwiftUI

/// The app's own version, or `shownVersion` in its place: a fixture's, so
/// a snapshot of it is the same from one version of the app to the next.
struct AboutSection: View {
    var shownVersion: String? = nil

    var body: some View {
        Section("About") {
            LabeledContent(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "", value: shownVersion ?? version)
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))"
    }
}
