#if canImport(UserNotifications)
import Foundation
import UserNotifications
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An app's updates, from Applications, in one call at launch:
///
///     AppUpdates.start()
///
/// The app writes the build it is to the database it shares with
/// Applications (in the group.com.LoganShire.Applications container), and
/// when Applications has said of a newer build, tells the user with a local
/// notification while the app is in the foreground: at launch, each time
/// it comes forward, and when Applications syncs a newer one while it runs.
/// Opening the notification, or its Install, installs the update
/// (`UpdateInstaller`). A Mac app that updates itself registers its handler
/// first: `AppUpdates.register(updateHandler:)`.
@MainActor
public final class AppUpdates {
    /// Applications on the Mac: its one bundle id, the iPhone's too (since
    /// 2026-11-01), then the Mac's two before it, for a Mac that still has
    /// one of those.
    public static let macApplicationsBundleIDs = ["com.LoganShire.Applications", "com.LoganShire.Applications.Mac",
                                                  "com.LoganShire.Applications.Mac.Beta"]

    private static var handler: UpdateHandler?
    private static var store: AppGroupStore?
    private static var signal: UpdateSignal?
    private static var checker: UpdateChecker?
    /// Kept: the notification center holds its delegate weakly.
    private static var delegate: UpdateNotificationDelegate?
    private static var watching: Task<Void, Never>?
    private static var foregroundObserver: (any NSObjectProtocol)?
    private static let log = Logger(subsystem: "ApplicationUpdates", category: "updates")

    private init() {}

    /// A Mac app's own install of its updates (OS Server, Visor Runner,
    /// Applications Server): called with the update in place of asking
    /// Applications and quitting. Register before `start`.
    public static func register(updateHandler: @escaping UpdateHandler) {
        handler = updateHandler
    }

    /// Starts at launch: writes the app's build and checks for a newer one
    /// now, when it comes to the foreground and when Applications syncs.
    /// `tellsOfUpdates: false` only writes the build (Applications itself,
    /// which tells of its own updates). An app without the group's
    /// container (its entitlements, its profile) logs why and does nothing.
    public static func start(appGroup: String = AppGroupStore.applicationsAppGroup, tellsOfUpdates: Bool = true) {
        guard checker == nil, let app = InstalledApp.main() else { return }
        let store: AppGroupStore
        do {
            store = try AppGroupStore.appGroup(appGroup)
        } catch {
            log.error("No updates: \(String(describing: error), privacy: .public)")
            return
        }
        let signal = UpdateSignal(appGroup: appGroup)
        let checker = UpdateChecker(store: store, app: app, presenter: NotificationPresenter(appName: appName), tells: tellsOfUpdates)
        Self.store = store
        Self.signal = signal
        Self.checker = checker
        Task { await check() }
        guard tellsOfUpdates else { return }
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil {
            let delegate = UpdateNotificationDelegate()
            Self.delegate = delegate
            center.delegate = delegate
        }
        Task { await addCategory() }
        foregroundObserver = NotificationCenter.default.addObserver(forName: becameActive, object: nil, queue: .main) { _ in
            Task { @MainActor in await AppUpdates.check() }
        }
        watching = Task {
            for await _ in signal.changes() { await check() }
        }
    }

    /// Checks again now.
    public static func check() async {
        guard let checker else { return }
        do {
            try await checker.check()
        } catch {
            log.error("The update check failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Installs an update: the handler's way, iOS's install link, or
    /// Applications asked and the app quit (`UpdateInstaller`).
    public static func install(_ update: AvailableUpdate) async {
        guard let store, let signal, let checker else { return }
        let installer = UpdateInstaller(store: store, system: AppleUpdateSystem(signal: signal, applicationsBundleIDs: macApplicationsBundleIDs),
                                        handler: handler, requester: checker.app.bundleID)
        do {
            _ = try await installer.install(update)
        } catch {
            log.error("The update did not install: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: For an app with a notification delegate of its own

    /// Whether a notification is an update's: shown in the foreground
    /// (`[.banner, .list, .sound]`) by an app's own delegate.
    public nonisolated static func isUpdateNotification(_ notification: UNNotification) -> Bool {
        notification.request.content.categoryIdentifier == NotificationPresenter.category
    }

    /// The update a notification the user opened (or chose Install on)
    /// offers, for `install`; nil for any other.
    public nonisolated static func update(from response: UNNotificationResponse) -> AvailableUpdate? {
        guard isUpdateNotification(response.notification),
              [UNNotificationDefaultActionIdentifier, NotificationPresenter.installAction].contains(response.actionIdentifier) else { return nil }
        return AvailableUpdate(userInfo: response.notification.request.content.userInfo)
    }

    // MARK: Inside

    /// The update notification's category beside the app's own. An app that
    /// sets its categories after `start` includes
    /// `NotificationPresenter.notificationCategory` in them.
    private nonisolated static func addCategory() async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.notificationCategories().filter { $0.identifier != NotificationPresenter.category }
        center.setNotificationCategories(existing.union([NotificationPresenter.notificationCategory]))
    }

    private static var appName: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? Bundle.main.bundleIdentifier ?? "This app"
    }

    private static var becameActive: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.didBecomeActiveNotification
        #else
        return NSApplication.didBecomeActiveNotification
        #endif
    }
}
#endif
