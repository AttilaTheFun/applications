import ApplicationUpdates
import ApplicationsProtocol
import PipelineClient
import UIKit
import UserNotifications

/// Where iOS delivers the push token and the notification the user taps.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Its own build to the database it shares with the apps, which tell
        // of their updates themselves; it tells of its own (docs/Updates.md).
        AppUpdates.start(tellsOfUpdates: false)
        UNUserNotificationCenter.current().delegate = self
        // A new build's notification offers Install: the app opens and
        // hands the build to iOS at once.
        let install = UNNotificationAction(identifier: Self.installAction, title: "Install", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "BUILD", actions: [install], intentIdentifiers: [])
        ])
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { await MainActor.run { application.registerForRemoteNotifications() } }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        ApplicationsStore.shared.didRegister(token: token, environment: Self.pushEnvironment, name: UIDevice.current.name)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("Applications: no push token: %@", String(describing: error))
    }

    /// Which of APNs's services the token is for, as the app was signed:
    /// "sandbox" under a development profile, "production" otherwise.
    static var pushEnvironment: String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return "production" }
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "<key>aps-environment</key>"),
              let open = text.range(of: "<string>", range: key.upperBound..<text.endIndex),
              let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex) else { return "production" }
        return text[open.upperBound..<close.lowerBound] == "development" ? "sandbox" : "production"
    }

    /// A notification arriving while the app is open: shown all the same.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated static let installAction = "INSTALL"

    /// The user opened a notification: its build — installed at once when
    /// they chose Install on it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let build = response.notification.request.content.userInfo["build"] as? String else { return }
        let install = response.actionIdentifier == Self.installAction
        await MainActor.run { ApplicationsStore.shared.open(build: build, installing: install) }
    }
}
