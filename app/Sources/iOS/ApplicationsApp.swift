import SwiftUI

/// Applications on the iPhone and the iPad: every app's builds to install
/// over the air, its production's and its beta's.
@main
struct ApplicationsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(ApplicationsStore.shared)
                .onOpenURL { ApplicationsStore.shared.open(link: $0) }
        }
    }
}
