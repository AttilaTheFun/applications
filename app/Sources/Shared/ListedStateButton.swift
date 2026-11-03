import ApplicationsProtocol
import SwiftUI

/// An app's state in the apps list as its button, one of four (the owner,
/// 2026-11-02): Install when no build of it is here; Unknown when it is here
/// but hasn't said which build, which opens it (opened, it says, and the
/// list asks again when Applications is back); Update when it said an older
/// build than the row's newest; Open when it said the newest. A spinner
/// while a build is on its way. Only those four titles (the owner,
/// 2026-11-03): an app here that Applications can't open (it lists no scheme
/// of it) is Open too, not tappable; Applications itself is Open.
struct ListedStateButton: View {
    @Environment(ApplicationsStore.self) private var store
    let builds: AppBuilds
    @State private var installing = false

    var body: some View {
        if let latest = builds.latest {
            if installing || store.installs.isBusy(builds) {
                ProgressView().controlSize(.small).frame(minWidth: 72)
            } else {
                switch store.installs.listedState(builds) {
                case .install: installButton("Install", latest)
                case .update: installButton("Update", latest)
                case .unknown: openButton("Unknown", "unknown-" + latest.id)
                case .open:
                    openButton("Open", "open-" + latest.id)
                        .disabled(builds.bundleID != Bundle.main.bundleIdentifier && !store.installs.canOpen(builds))
                }
            }
        }
    }

    private func installButton(_ title: String, _ build: Build) -> some View {
        Button(title) {
            installing = true
            Task {
                if let failure = await store.install(build) { store.failure = failure }
                installing = false
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityIdentifier("install-" + build.id)
    }

    /// Opens the app (Applications itself: nothing, it is open).
    private func openButton(_ title: String, _ identifier: String) -> some View {
        Button(title) {
            guard builds.bundleID != Bundle.main.bundleIdentifier else { return }
            Task { if let failure = await store.installs.open(builds) { store.failure = failure } }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityIdentifier(identifier)
    }
}
