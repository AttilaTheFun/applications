/// A version as apps carry it: CFBundleShortVersionString ("0.10.2") and,
/// beside it, CFBundleVersion (the build, "1" for an app whose version says
/// it all, MAJOR.MINOR.BUILD). Ordered part by part as numbers, so 0.10.2
/// comes after 0.9.34; a missing part counts as 0 (0.10 is 0.10.0); then by
/// build, when both have one.
public struct AppVersion: Sendable, Comparable, CustomStringConvertible {
    public let version: String
    /// Nil or empty: the build is not known, and does not decide.
    public let build: String?

    public init(_ version: String, build: String? = nil) {
        self.version = version
        self.build = build
    }

    /// "0.10.2", or "0.23 (23)" when the build is not the version's own.
    public var description: String {
        guard let build, !build.isEmpty, build != "1", build != version else { return version }
        return "\(version) (\(build))"
    }

    public static func < (left: AppVersion, right: AppVersion) -> Bool { compare(left, right) < 0 }

    public static func == (left: AppVersion, right: AppVersion) -> Bool { compare(left, right) == 0 }

    /// -1, 0 or 1: the versions, then the builds if both are known.
    static func compare(_ left: AppVersion, _ right: AppVersion) -> Int {
        let byVersion = compareDotted(left.version, right.version)
        guard byVersion == 0, let a = left.build, let b = right.build, !a.isEmpty, !b.isEmpty else { return byVersion }
        return compareDotted(a, b)
    }

    /// Dotted parts, each a number with what follows its digits after it
    /// ("1b2" is 1, then "b2"): 1 is after 1b2, as a release is after its
    /// betas. Numbers are compared by their digits, so none is too long.
    static func compareDotted(_ left: String, _ right: String) -> Int {
        let a = left.split(separator: ".", omittingEmptySubsequences: false)
        let b = right.split(separator: ".", omittingEmptySubsequences: false)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : "0", y = index < b.count ? b[index] : "0"
            let order = comparePart(x, y)
            if order != 0 { return order }
        }
        return 0
    }

    private static func comparePart(_ left: Substring, _ right: Substring) -> Int {
        let (leftNumber, leftRest) = split(left)
        let (rightNumber, rightRest) = split(right)
        if leftNumber.count != rightNumber.count { return leftNumber.count < rightNumber.count ? -1 : 1 }
        if leftNumber != rightNumber { return leftNumber < rightNumber ? -1 : 1 }
        if leftRest == rightRest { return 0 }
        // Nothing after the number is the release, after any suffix.
        if leftRest.isEmpty { return 1 }
        if rightRest.isEmpty { return -1 }
        return leftRest < rightRest ? -1 : 1
    }

    /// The part's leading digits without leading zeros ("" for 0), and the rest.
    private static func split(_ part: Substring) -> (Substring, Substring) {
        let digits = part.prefix { $0.isASCII && $0.isNumber }
        let number = digits.drop { $0 == "0" }
        return (number, part.dropFirst(digits.count))
    }
}
