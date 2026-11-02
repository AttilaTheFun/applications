import ApplicationsProtocol
import Foundation
import UserNotifications

/// A Mac is told of each newer build of an app it has, once: the server
/// pushes to phones, and a Mac asks it every few minutes.
@MainActor
enum NewBuildNotices {
    private static let toldKey = "told"

    static func tell(_ store: ApplicationsStore) async {
        var told = Set(UserDefaults.standard.stringArray(forKey: toldKey) ?? [])
        for app in store.apps {
            for builds in store.appBuilds(app) where store.installs.standing(builds) == .updateAvailable {
                guard let latest = builds.latest, !told.contains(latest.id) else { continue }
                told.insert(latest.id)
                let content = UNMutableNotificationContent()
                content.title = "A new \(latest.name) build is ready to install"
                let summary = ReleaseNotes(latest.notes).summary
                content.body = "\(latest.name) \(latest.versionTitle)" + (summary.isEmpty ? "" : " — " + summary)
                content.categoryIdentifier = "BUILD"
                content.userInfo = ["build": latest.id]
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: latest.id, content: content, trigger: nil))
            }
        }
        UserDefaults.standard.set(Array(told), forKey: toldKey)
    }
}
