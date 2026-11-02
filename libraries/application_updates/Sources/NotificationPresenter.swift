#if canImport(UserNotifications)
import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Tells of an update with a local notification, with Install on it. The
/// user is asked for notifications the first time there is one to show;
/// one already refused shows nothing.
public struct NotificationPresenter: UpdatePresenter {
    public static let category = "APPLICATION_UPDATE"
    public static let installAction = "APPLICATION_UPDATE_INSTALL"

    /// The app's name, as under its icon.
    public let appName: String

    public init(appName: String) {
        self.appName = appName
    }

    /// The notification's category, with its Install action (which brings
    /// the app forward, as installing needs it there).
    public static var notificationCategory: UNNotificationCategory {
        let install = UNNotificationAction(identifier: installAction, title: "Install", options: [.foreground])
        return UNNotificationCategory(identifier: category, actions: [install], intentIdentifiers: [])
    }

    public func isInForeground() async -> Bool {
        await MainActor.run {
            #if canImport(UIKit)
            return UIApplication.shared.applicationState == .active
            #elseif canImport(AppKit)
            return NSApplication.shared.isActive
            #else
            return true
            #endif
        }
    }

    public func present(_ update: AvailableUpdate) async {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        case .denied:
            return
        default:
            break
        }
        let content = UNMutableNotificationContent()
        content.title = "\(appName) \(update.latest) is available"
        content.body = "You have \(update.installed). Install the update now."
        content.categoryIdentifier = Self.category
        content.userInfo = update.userInfo
        content.sound = .default
        // One a bundle id: a newer update's replaces an older one's.
        let request = UNNotificationRequest(identifier: "application-update." + update.bundleID, content: content, trigger: nil)
        try? await center.add(request)
    }
}
#endif
