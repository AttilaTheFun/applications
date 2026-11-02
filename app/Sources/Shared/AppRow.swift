import ApplicationsProtocol
import SwiftUI

/// An app in the list, one row for its production and its betas: its icon
/// and name (production's), the newest build's numbers (its production's,
/// else its beta's, marked Beta; and what is installed, when it is older),
/// and its state as a button (ListedStateButton): Install, Unknown, Update
/// or Open, a spinner while a build is on its way.
struct AppRow: View {
    @Environment(ApplicationsStore.self) private var store
    let listing: AppListing

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(id: listing.shown?.latest?.id ?? listing.app.iconBuild, size: DeviceInstalls.iconSize) { await store.icon(build: $0) }
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(listing.versionTitle).lineLimit(1)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if listing.showsBeta, let latest = listing.shown?.latest { ChannelBadge(build: latest) }
                }
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let shown = listing.shown { ListedStateButton(builds: shown) }
        }
        .padding(.vertical, 2)
    }

    /// What is installed, when it is older: of any variant (one bundle id is
    /// one app).
    private var detail: String? {
        guard let builds = listing.shown, store.installs.listedState(builds) == .update,
              let installed = store.installs.listedInstalled(builds) else { return nil }
        // The same numbers: a newer build of them.
        if installed.version == listing.versionTitle { return "A newer build" }
        return "You have \(installed.version)"
    }
}
