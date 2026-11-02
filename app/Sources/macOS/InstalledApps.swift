import AppKit
import ApplicationsProtocol

/// What is installed on this Mac, read from the apps themselves: the copy
/// in /Applications (or ~/Applications), its numbers, its variant and its
/// executable's UUID. No app needs to say anything. Each bundle id is an app of its own:
/// a beta (`<id>.Beta`) is told apart from its production, and installed
/// beside it.
enum InstalledApps {
    /// Where the app is installed, or where it goes when it is not: the
    /// copy in an Applications folder that Launch Services knows, else
    /// /Applications/<name>.app, unless an app of another bundle id is
    /// there (a beta named as its production is), when it is named after
    /// its own id.
    static func location(bundleID: String, name: String) -> URL {
        let folders = ["/Applications/", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"]
        let known = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
        if let found = known.first(where: { url in folders.contains { url.path.hasPrefix($0) } }) { return found }
        let named = URL(fileURLWithPath: "/Applications/\(name).app")
        guard let there = Bundle(url: named)?.bundleIdentifier, there != bundleID else { return named }
        return URL(fileURLWithPath: "/Applications/\(name) (\(bundleID)).app")
    }

    /// The build installed of an app, or nil.
    static func installed(bundleID: String, name: String) -> InstalledBuild? {
        let url = bundleID == Bundle.main.bundleIdentifier ? Bundle.main.bundleURL : location(bundleID: bundleID, name: name)
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleID else { return nil }
        let info = bundle.infoDictionary ?? [:]
        return InstalledBuild(bundleID: bundleID, version: info["CFBundleShortVersionString"] as? String ?? "",
                              buildNumber: info["CFBundleVersion"] as? String ?? "",
                              executableUUID: bundle.executableURL.flatMap(MachOUUID.uuid(ofFileAt:)) ?? "",
                              variant: info["BuildVariant"] as? String)
    }
}
