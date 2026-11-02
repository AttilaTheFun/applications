/// An app's two builds, side by side on one device (docs/VARIANTS.md):
/// production, `com.LoganShire.<App>` under the app's own name, and the
/// beta, `com.LoganShire.<App>.Beta`, named "<App> β". Both are one app
/// here: the server lists them under one name and Applications in one row.
public enum BundleVariant {
    /// What a beta's bundle id ends with.
    public static let betaSuffix = ".Beta"
    /// What a beta's name ends with, under its icon.
    public static let betaMark = " β"

    /// Whether a bundle id is a beta's: such a build is never production.
    public static func isBeta(_ bundleID: String) -> Bool {
        bundleID.hasSuffix(betaSuffix) && bundleID.count > betaSuffix.count
    }

    /// The production app's bundle id: `<id>` for `<id>.Beta`, any other as
    /// it is.
    public static func productionID(_ bundleID: String) -> String {
        isBeta(bundleID) ? String(bundleID.dropLast(betaSuffix.count)) : bundleID
    }

    /// The production app's name: "Visor" for the beta's "Visor β"; a
    /// production build's name as it is.
    public static func productionName(_ name: String, bundleID: String) -> String {
        guard isBeta(bundleID), name.hasSuffix(betaMark), name.count > betaMark.count else { return name }
        return String(name.dropLast(betaMark.count))
    }

    /// Whether `old` is one of `id`'s bundle ids from before one bundle id
    /// an app (2026-11-01): its beta's `<id>.Beta`, and on a Mac `<id>.Mac`
    /// and `<id>.Mac.Beta`. An install of `id` replaces such an app.
    public static func isEarlierID(_ old: String, of id: String) -> Bool {
        [betaSuffix, ".Mac", ".Mac" + betaSuffix].contains { id + $0 == old }
    }
}
