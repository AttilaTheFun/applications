import AppKit
import ApplicationUpdates
import ApplicationsProtocol

/// The apps' requests to install their updates: on a Mac an app asks
/// Applications through the database they share and quits
/// (ApplicationUpdates' UpdateInstaller), with no URL scheme. Taken at
/// launch and whenever the database changes while Applications runs (the
/// group's Darwin notification), each installed with the app's newest build
/// here, its page open while it goes, and the app opened again after.
@MainActor
enum InstallRequests {
    private static var watching: Task<Void, Never>?

    static func watch(_ store: ApplicationsStore) {
        guard watching == nil, let updates = store.updates else { return }
        watching = Task {
            await take(store, updates)
            // One at a time: a change heard while installing is looked at after.
            for await _ in UpdateSignal().changes() { await take(store, updates) }
        }
    }

    private static func take(_ store: ApplicationsStore, _ updates: AppGroupStore) async {
        let requests: [InstallRequest]
        do {
            requests = try await updates.takeInstallRequests()
        } catch {
            store.failure = "The apps' install requests can't be read: \(error)"
            return
        }
        guard !requests.isEmpty else { return }
        await store.refresh()
        for request in requests {
            guard let group = store.apps.flatMap(store.appBuilds).first(where: { $0.bundleID == request.bundleID }),
                  let build = group.latest else {
                store.failure = "\(request.bundleID) asked for its update, but Applications has no build of it for this Mac."
                continue
            }
            NSApp.activate()
            store.selection = build.productionBundleID
            store.path = [.build(build.id)]
            if let failure = await store.install(build) {
                store.failure = "\(group.name) did not update: \(failure)"
                continue
            }
            // The app quit to be updated: opened again, now updated.
            if request.requestedBy == request.bundleID { _ = await store.installs.open(group) }
        }
    }
}
