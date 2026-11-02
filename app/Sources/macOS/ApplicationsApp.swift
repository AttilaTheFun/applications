import SwiftUI

/// Applications on the Mac: every app's builds to install in place, its
/// production builds and its betas.
@main
struct ApplicationsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(ApplicationsStore.shared)
                .onOpenURL { ApplicationsStore.shared.open(link: $0) }
        }
    }
}
