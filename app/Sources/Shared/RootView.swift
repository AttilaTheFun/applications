import SwiftUI

/// Applications: this device's apps beside the one open (its production
/// builds and its betas, a build to install, its versions); the server in
/// Settings, from the list's toolbar.
struct RootView: View {
    @Environment(ApplicationsStore.self) private var store
    @Environment(\.scenePhase) private var phase
    /// The window's width, read here, outside the split view (a column's
    /// own is compact even on an iPad).
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// On a phone, the column shown: the app open, once there is one.
    @State private var column: NavigationSplitViewColumn = .sidebar

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(preferredCompactColumn: $column) {
            AppsList(titled: sizeClass == .compact)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        } detail: {
            NavigationStack(path: $store.path) {
                Group {
                    if let bundleID = store.selection {
                        AppBuildsView(bundleID: bundleID)
                    } else {
                        ContentUnavailableView("Pick an app", systemImage: "arrow.down.app",
                                               description: Text("Its builds for this \(DeviceInstalls.deviceName), and its versions."))
                            .navigationTitle("Applications")
                    }
                }
                .navigationDestination(for: ApplicationsRoute.self) { route in
                    switch route {
                    case .build(let id): BuildView(id: id)
                    case .version(let app, let version): ReleaseVersionView(app: app, version: version)
                    }
                }
            }
        }
        .onAppear { if store.selection != nil { column = .detail } }
        .onChange(of: store.selection) { old, now in
            if old != nil && now != old { store.path = [] }
            if now != nil { column = .detail }
        }
        .sheet(isPresented: $store.showingSettings) { SettingsView() }
        .task { await store.refresh() }
        // Back in front: the path chosen again (the LAN at home, the
        // tailnet away).
        .onChange(of: phase) { _, now in if now == .active { Task { await store.refresh() } } }
        .alert("Applications", isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })) {
            Button("OK") { store.failure = nil }
        } message: {
            Text(store.failure ?? "")
        }
    }
}
