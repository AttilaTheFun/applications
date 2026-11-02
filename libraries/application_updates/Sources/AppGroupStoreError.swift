/// Why the shared database can't be had.
public enum AppGroupStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The app group's container is not this app's: its entitlements (and
    /// on an iPhone, or a Mac app outside the App Store from macOS 15, its
    /// provisioning profile) don't grant the group.
    case noContainer(appGroup: String)

    public var description: String {
        switch self {
        case .noContainer(let group): return "No container for the app group \(group): the app's entitlements and profile must grant it"
        }
    }
}
