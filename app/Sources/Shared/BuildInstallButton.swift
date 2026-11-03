import ApplicationsProtocol
import Foundation
import SwiftUI

/// A build's state on this device as a button: Install (Update, for the
/// newest when an older one is here), a spinner while it is on its way, or
/// Open once it is here (for Applications itself too, where it does nothing:
/// Applications is open already), not tappable for an app here that
/// Applications cannot open: the titles are Open, Update and Install alone.
struct BuildInstallButton: View {
    @Environment(ApplicationsStore.self) private var store
    let builds: AppBuilds
    let build: Build
    @State private var installing = false

    var body: some View {
        if installing || store.installs.isBusy(builds) {
            ProgressView().controlSize(.small).frame(minWidth: 72)
        } else if installedHere, store.installs.canOpen(builds) {
            openButton {
                Task { if let failure = await store.installs.open(builds) { store.failure = failure } }
            }
        } else if installedHere, builds.bundleID == Bundle.main.bundleIdentifier {
            openButton {}
        } else if installedHere {
            openButton {}
                .disabled(true)
        } else {
            Button(newest && store.installs.standing(builds) == .updateAvailable ? "Update" : "Install") {
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
    }

    private func openButton(_ action: @escaping () -> Void) -> some View {
        Button("Open", action: action)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .accessibilityIdentifier("open-" + build.id)
    }

    private var newest: Bool { build.id == builds.latest?.id }

    /// This build is the one here (the newest, too, when what is here is
    /// newer than any published).
    private var installedHere: Bool {
        store.installs.installedBuild(builds)?.id == build.id || (newest && store.installs.standing(builds) == .upToDate)
    }
}
