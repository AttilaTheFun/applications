import ApplicationUpdates
import ApplicationsProtocol
import Foundation

/// What Applications tells the apps it distributes, through the database
/// they share (ApplicationUpdates, docs/Updates.md): each bundle's newest
/// build on this device, and where it installs from, written after each
/// sync with the server. Each app reads its own row at launch and tells the
/// user when it is newer than itself.
enum UpdateFeed {
    /// Each bundle's newest build here, a production build's id taken by
    /// its production builds before any beta published under it.
    /// `address` is the server's that answered: the install links go to it.
    static func latest(_ groups: [AppBuilds], address: String) -> [LatestBuild] {
        var seen = Set<String>()
        return groups.compactMap { group in
            guard seen.insert(group.bundleID).inserted, let build = group.latest else { return nil }
            return LatestBuild(bundleID: build.bundleID, version: build.version, build: build.buildNumber.isEmpty ? nil : build.buildNumber,
                               installURL: DeviceInstalls.installURL(of: build, at: address))
        }
    }
}
