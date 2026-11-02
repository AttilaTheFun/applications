import AppKit
import ApplicationUpdates
import UserNotifications

/// The notifications a Mac shows of new builds, and the asking of the
/// server every five minutes and when the Mac wakes.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Its own build to the database it shares with the apps (it tells
        // of its own updates itself), and the apps' requests to install
        // theirs, now and as they come (docs/Updates.md).
        AppUpdates.start(tellsOfUpdates: false)
        InstallRequests.watch(ApplicationsStore.shared)
        UNUserNotificationCenter.current().delegate = self
        let install = UNNotificationAction(identifier: Self.installAction, title: "Install", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "BUILD", actions: [install], intentIdentifiers: [])
        ])
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        Task { @MainActor in
            while !Task.isCancelled {
                await ApplicationsStore.shared.refresh()
                await NewBuildNotices.tell(ApplicationsStore.shared)
                // Again in five minutes; in half a minute while the server
                // can't be reached (the local network not yet allowed).
                let wait: UInt64 = ApplicationsStore.shared.problem == nil ? 300 : 30
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                await ApplicationsStore.shared.refresh()
                await NewBuildNotices.tell(ApplicationsStore.shared)
            }
        }
    }

    nonisolated static let installAction = "INSTALL"

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let build = response.notification.request.content.userInfo["build"] as? String else { return }
        let install = response.actionIdentifier == Self.installAction
        await MainActor.run {
            NSApp.activate()
            ApplicationsStore.shared.open(build: build, installing: install)
        }
    }
}
