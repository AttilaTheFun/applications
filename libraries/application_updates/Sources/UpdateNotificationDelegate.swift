#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// The notification center's delegate, for an app that has none of its own:
/// update notifications shown while the app is in the foreground (where
/// they are told), and opening one, or its Install, installs the update.
/// An app with its own delegate asks `AppUpdates` the same from it.
final class UpdateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        AppUpdates.isUpdateNotification(notification) ? [.banner, .list, .sound] : []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let update = AppUpdates.update(from: response) else { return }
        await AppUpdates.install(update)
    }
}
#endif
