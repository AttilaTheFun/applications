#if canImport(UserNotifications)
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Installing on Apple's systems: UIKit's or AppKit's opening of URLs and
/// apps, AppKit's quitting, and the group's Darwin notification.
struct AppleUpdateSystem: UpdateSystem {
    let signal: UpdateSignal
    /// Applications on the Mac, production's before the beta's: whichever
    /// is installed is asked (both read the same database).
    let applicationsBundleIDs: [String]

    @MainActor
    func open(_ url: URL) async -> Bool {
        #if canImport(UIKit)
        return await UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
    }

    @MainActor
    func openApplications() async throws {
        #if canImport(AppKit) && !canImport(UIKit)
        guard let url = applicationsBundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else {
            throw UpdateInstallError.applicationsNotInstalled
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        #else
        throw UpdateInstallError.applicationsNotInstalled
        #endif
    }

    @MainActor
    func terminate() async {
        #if canImport(AppKit) && !canImport(UIKit)
        // As Quit in the menu: the app's delegate may still finish its work.
        NSApplication.shared.terminate(nil)
        #endif
    }

    func databaseChanged() { signal.post() }
}
#endif
