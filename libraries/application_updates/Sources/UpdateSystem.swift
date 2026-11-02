import Foundation

/// What installing asks of the system: Apple's (`AppleUpdateSystem`), or a
/// stand-in in tests.
public protocol UpdateSystem: Sendable {
    /// Opens a URL (an over-the-air install link): whether the system took it.
    func open(_ url: URL) async -> Bool
    /// Opens Applications, or brings it forward: throws when it is not installed.
    func openApplications() async throws
    /// Quits the app as the user quitting it would.
    func terminate() async
    /// Tells the other apps of the group that the database changed.
    func databaseChanged() async
}
