/// The URL schemes Applications asks iOS about: the one thing iOS says of
/// another app is whether some app opens a scheme, and only for the
/// schemes the asking app lists (LSApplicationQueriesSchemes, at most 50).
///
/// A build's scheme is `applications-<release>-build-<n>`: the release is
/// Applications' (MAJOR.MINOR of its version), and its numbers are that
/// release's alone, given out in order and never again. Applications lists
/// its own release's 50; the server gives other apps' builds 1…49 and
/// keeps 50 back as the guard: once 49 are out, only a new Applications
/// build, of a newer release, opens more. Production builds alone carry
/// one (a beta is never asked about): CI's release job asks the server for
/// the build's scheme before building it and stamps it into the app's
/// Info.plist. Applications itself needs none: it knows its own version.
public enum BuildSchemes {
    /// How many schemes a release has, all of them listed by its Applications.
    public static let count = 50
    /// How many of them go to other apps' builds; the last is held back.
    public static let othersLimit = 49

    /// Applications on the iPhone and iPad: its production builds set the
    /// server's release, and need no scheme.
    public static let applicationsBundleID = "com.LoganShire.Applications"

    /// The name of the URL type a build's scheme goes in under
    /// (CFBundleURLName), stamped by CI or added by the server.
    public static let urlName = "applications-build"

    private static let prefix = "applications-"
    private static let infix = "-build-"

    /// "applications-0.6-build-3".
    public static func scheme(release: String, number: Int) -> String { prefix + release + infix + String(number) }

    /// The release and number a build's scheme names, or nil for any other
    /// scheme.
    public static func parse(_ scheme: String?) -> (release: String, number: Int)? {
        guard let scheme, scheme.hasPrefix(prefix), let infixRange = scheme.range(of: infix, options: .backwards) else { return nil }
        let release = String(scheme[scheme.index(scheme.startIndex, offsetBy: prefix.count)..<infixRange.lowerBound])
        let digits = scheme[infixRange.upperBound...]
        guard Self.release(of: release) == release, isNumber(digits), let number = Int(digits), String(number) == digits,
              (1...count).contains(number) else { return nil }
        return (release, number)
    }

    /// A version's release, MAJOR.MINOR: "0.6.3" is 0.6's, and "0.6" is a
    /// release already. Nil for a version that is not numbers.
    public static func release(of version: String) -> String? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy(isNumber) else { return nil }
        return "\(parts[0]).\(parts[1])"
    }

    private static func isNumber(_ text: Substring) -> Bool { !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber } }

    /// A release's 50 schemes. Applications listed them in its Info.plist's
    /// LSApplicationQueriesSchemes until 2026-11-02, when it took to the apps'
    /// own link schemes (DeviceInstalls on the iPhone).
    public static func all(release: String) -> [String] { (1...count).map { scheme(release: release, number: $0) } }
}
