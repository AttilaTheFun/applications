import SwiftUI

/// This device's apps, each with Install, Update or Open; Settings
/// (the server) in the toolbar, at the top left: on a phone in
/// the list's bar, beside the sidebar's button elsewhere.
struct AppsList: View {
    @Environment(ApplicationsStore.self) private var store
    /// In one column (a phone): titled. Said by the root, outside the split
    /// view, whose sidebar column is compact on its own even on an iPad.
    var titled = true

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            if let problem = store.problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            ForEach(store.listings) { listing in
                AppRow(listing: listing).tag(listing.id)
            }
        }
        // Titled in one column (a phone); beside the detail (an iPad, a
        // Mac) not: the detail's title is the app's, or the app open.
        .navigationTitle(titled ? "Applications" : "")
        .settingsToolbar { store.showingSettings = true }
        .overlay { empty }
        .refreshable { await store.refresh() }
    }

    @ViewBuilder private var empty: some View {
        if store.code == nil && !store.showsFixture {
            ContentUnavailableView {
                Label("No server", systemImage: "server.rack")
            } description: {
                Text("Connect to one in Settings.")
            } actions: {
                Button("Settings") { store.showingSettings = true }
            }
        } else if store.listings.isEmpty && !store.isRefreshing && store.problem == nil {
            ContentUnavailableView("Nothing for this \(DeviceInstalls.deviceName) yet", systemImage: "shippingbox",
                                   description: Text("Apps appear as their builds for it are published."))
        }
    }
}
