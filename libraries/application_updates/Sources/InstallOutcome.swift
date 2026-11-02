/// What installing an update did.
public enum InstallOutcome: Sendable, Equatable {
    /// The app's update handler installed it.
    case handled
    /// The over-the-air install link was opened (iOS asks the user).
    case openedInstallLink
    /// Applications was asked to install it, and the app quit.
    case askedApplications
}
