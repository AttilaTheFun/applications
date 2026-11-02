import ApplicationsProtocol
import Foundation

/// A row of the apps list: an app's builds of one bundle on this device,
/// its beta's (`<id>.Beta`) with its production's, as one app, under the
/// production's bundle id (Visor and Visor Server are two rows on a Mac;
/// Visor and Visor β one, as are a Mac's `<id>.Mac` and `<id>.Mac.Beta`).
/// Each kind of build stays with its own bundle id, by which what is
/// installed is told apart.
struct AppListing: Identifiable {
    let app: AppRelease
    /// The production app's bundle id, which the row goes by.
    let id: String
    /// Its production builds here, newest first; nil when it has none.
    let production: AppBuilds?
    /// Its betas here, by bundle id, the newest first: `<id>.Beta`'s, and
    /// `<id>`'s published as betas (a CI that builds commits with the
    /// production id).
    let betas: [AppBuilds]

    /// Every kind of its builds here: production's first.
    var groups: [AppBuilds] { (production.map { [$0] } ?? []) + betas }
    /// What the row shows: its latest Alpha (main's newest, what's being
    /// tested), its bundle's Alphas alone, so its numbers, its badge and
    /// its Install agree; else its production builds; else its newest Beta;
    /// else its newest of any other (an AdHoc's, a pull request's own build,
    /// which never stands for the app while there is another).
    var shown: AppBuilds? {
        only("Alpha") ?? production ?? only("Beta") ?? betas.first
    }
    /// The row shows a build that isn't production: its numbers are its
    /// latest Alpha's (or another's), marked with its variant.
    var showsBeta: Bool { shown.map { $0.latest?.channel != .production } ?? false }

    /// Its betas' builds of one variant, the bundle with the newest of them,
    /// those alone; nil when it has none.
    private func only(_ variant: String) -> AppBuilds? {
        let kept = betas.compactMap { builds -> AppBuilds? in
            let of = builds.builds.filter { BuildVariants.variant(of: $0) == variant }
            return of.isEmpty ? nil : AppBuilds(bundleID: builds.bundleID, name: builds.name, builds: of)
        }
        return kept.max { ($0.latest?.published ?? .distantPast) < ($1.latest?.published ?? .distantPast) }
    }
    /// The app's own name ("Visor Server"), as production names it: a
    /// beta's without its mark.
    var name: String {
        production?.name ?? betas.first.map { BundleVariant.productionName($0.name, bundleID: $0.bundleID) } ?? id
    }
    /// The shown build's numbers.
    var versionTitle: String { shown?.latest?.versionTitle ?? "" }

    /// This device's builds of an app (one platform's), as rows: by
    /// production bundle id, each kind of build apart.
    static func rows(_ app: AppRelease, builds: [Build]) -> [AppListing] {
        var order: [String] = []
        var byApp: [String: [Build]] = [:]
        for build in builds.sorted(by: { $0.published > $1.published }) {
            if byApp[build.productionBundleID] == nil { order.append(build.productionBundleID) }
            byApp[build.productionBundleID, default: []].append(build)
        }
        let rows = order.map { id in
            let built = byApp[id] ?? []
            return AppListing(app: app, id: id, production: byBundle(built.filter { $0.channel == .production }).first,
                              betas: byBundle(built.filter { $0.channel != .production }))
        }
        return newestOfEachName(rows)
    }

    /// One row a name: an app that moved to another bundle id (Visor's
    /// iPhone app, com.LoganShire.VisorClient.iOS before one bundle id an
    /// app, com.LoganShire.Visor after) is one app, under the bundle id of
    /// its newest build; its earlier id's row goes, as only one of the two
    /// is the app now. Apps of different names (Visor and Visor Server on
    /// a Mac) keep their rows. The order as it was.
    static func newestOfEachName(_ rows: [AppListing]) -> [AppListing] {
        func newest(_ row: AppListing) -> Date { row.groups.compactMap { $0.latest?.published }.max() ?? .distantPast }
        var kept: [String: AppListing] = [:]
        for row in rows where kept[row.name].map({ newest($0) < newest(row) }) ?? true { kept[row.name] = row }
        return rows.filter { kept[$0.name]?.id == $0.id }
    }

    /// Builds by bundle id, the bundle with the newest first, each newest
    /// first.
    static func byBundle(_ builds: [Build]) -> [AppBuilds] {
        var order: [String] = []
        var byBundle: [String: [Build]] = [:]
        for build in builds.sorted(by: { $0.published > $1.published }) {
            if byBundle[build.bundleID] == nil { order.append(build.bundleID) }
            byBundle[build.bundleID, default: []].append(build)
        }
        return order.map { AppBuilds(bundleID: $0, name: byBundle[$0]?.first?.name ?? $0, builds: byBundle[$0] ?? []) }
    }
}
