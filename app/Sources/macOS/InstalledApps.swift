import AppKit
import ApplicationsProtocol

/// What is installed on this Mac, read from the apps themselves: the copy
/// in /Applications (or ~/Applications), its numbers, its variant and its
/// executable's UUID. No app needs to say anything. One bundle id is one
/// app, installed under its own name.
enum InstalledApps {
    static let folders = ["/Applications/", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"]

    /// Where the app is installed, or nil: the copy in an Applications
    /// folder Launch Services knows (one under its own name first), else
    /// /Applications/<name>.app if that is it.
    static func current(bundleID: String, name: String) -> URL? {
        let known = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).filter { url in folders.contains { url.path.hasPrefix($0) } }
        if let own = known.first(where: { $0.lastPathComponent == "\(name).app" }) { return own }
        if let found = known.first { return found }
        let named = URL(fileURLWithPath: "/Applications/\(name).app")
        return Bundle(url: named)?.bundleIdentifier == bundleID ? named : nil
    }

    /// Where an install puts the app: where it is now under its own name;
    /// else /Applications/<name>.app when that is free, the app itself, or
    /// one of its earlier bundle ids (`earlier`, the catalog's other ids
    /// under its name, and BundleVariant.isEarlierID's: the same app before
    /// one bundle id an app, which the install replaces); else, beside an
    /// unrelated app of its name, where it is now or named after its id.
    static func destination(bundleID: String, name: String, earlier: Set<String>) -> URL {
        let current = current(bundleID: bundleID, name: name)
        if let current, current.lastPathComponent == "\(name).app" { return current }
        let named = URL(fileURLWithPath: "/Applications/\(name).app")
        guard let there = Bundle(url: named)?.bundleIdentifier, there != bundleID, !earlier.contains(there),
              !BundleVariant.isEarlierID(there, of: bundleID) else { return named }
        return current ?? URL(fileURLWithPath: "/Applications/\(name) (\(bundleID)).app")
    }

    /// The build installed of an app, or nil.
    static func installed(bundleID: String, name: String) -> InstalledBuild? {
        let url = bundleID == Bundle.main.bundleIdentifier ? Bundle.main.bundleURL : current(bundleID: bundleID, name: name)
        guard let url, let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleID else { return nil }
        let info = bundle.infoDictionary ?? [:]
        return InstalledBuild(bundleID: bundleID, version: info["CFBundleShortVersionString"] as? String ?? "",
                              buildNumber: info["CFBundleVersion"] as? String ?? "",
                              executableUUID: bundle.executableURL.flatMap(MachOUUID.uuid(ofFileAt:)) ?? "",
                              variant: info["BuildVariant"] as? String)
    }
}
