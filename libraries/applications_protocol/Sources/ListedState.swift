/// What the apps list says of an app on this device, one of four (the
/// owner, 2026-11-02): Install when no build of it is here; Unknown when it
/// is here but has not said which build (it hasn't been opened since it
/// could: tapping opens it, and it says); Update when it said a build older
/// than the row's newest; Open when it said the newest, or newer.
public enum ListedState: Sendable, Equatable {
    case install
    case unknown
    case update
    case open
}

extension AppBuilds {
    /// This app's state in the list. `here`: whether the app is on this
    /// device (its own link scheme opens), nil where that can't be asked;
    /// `installed`: the build it last said it is, of any of its bundle id's
    /// builds (an Alpha, Beta, AdHoc or Production: one bundle id is one app
    /// installed at a time), compared with these builds' newest.
    public func listedState(here: Bool?, installed: InstalledBuild?) -> ListedState {
        if here == false { return .install }
        guard let installed else { return here == true ? .unknown : .install }
        return standing(installed) == .updateAvailable ? .update : .open
    }
}
