/// Where this device stands with an app's newest published build.
public enum InstallStanding: Sendable, Equatable {
    /// The newest build, or one newer than any published, is installed.
    case upToDate
    /// An older build is installed.
    case updateAvailable
    /// The app did not say what is installed, if anything.
    case unknown
    /// The app is installed (its link scheme opens), but it has not said
    /// which build: it has not run since it could, or it writes nothing.
    case installedUnknownVersion
}
