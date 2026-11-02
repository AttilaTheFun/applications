/// Who tells the user of an update: a local notification on Apple's
/// systems (`NotificationPresenter`), a stand-in in tests.
public protocol UpdatePresenter: Sendable {
    /// Whether the app is in the foreground: an update is told only then.
    func isInForeground() async -> Bool
    func present(_ update: AvailableUpdate) async
}
