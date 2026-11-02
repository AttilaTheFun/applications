/// How an update installs.
public enum UpdatePlatform: Sendable, Equatable {
    /// An iPhone or an iPad: the build's over-the-air install link is
    /// opened; iOS asks, then ends the app to replace it.
    case iOS
    /// A Mac: the app's update handler, if it registered one, else
    /// Applications is asked, and the app quits.
    case macOS

    /// This build's.
    public static var current: UpdatePlatform {
        #if os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }
}
