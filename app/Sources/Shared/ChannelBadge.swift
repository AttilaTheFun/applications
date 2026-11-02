import ApplicationsProtocol
import SwiftUI

/// A build's channel, or its variant (Alpha, Beta, Production), as a small
/// capsule: green for production, orange otherwise.
struct ChannelBadge: View {
    let title: String
    let isProduction: Bool

    init(channel: ReleaseChannel) {
        title = channel.title
        isProduction = channel == .production
    }

    /// A build's variant: its `BuildVariant`, else as its channel says
    /// (main's builds before variants were Alphas).
    init(build: Build) {
        title = BuildVariants.variant(of: build)
        isProduction = title == "Production"
    }

    var body: some View {
        let words = Text(title)
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .lineLimit(1)
        words.hidden()
            // Its colour as a fill cut to the words, not the words coloured:
            // in an iPad's sidebar (the apps list beside an app) coloured
            // text drew black, where a fill keeps its colour.
            .overlay { (isProduction ? Color.white : Color.orange).mask { words } }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(isProduction ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.orange.opacity(0.18)), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
    }
}

/// Builds by variant, and in version order.
enum BuildVariants {
    static let order = ["Alpha", "Beta", "Production"]

    /// Its `BuildVariant`, else Production for a production build and Alpha
    /// for any other (main's builds before variants).
    static func variant(of build: Build) -> String { build.variant }

    /// Whether `a` comes after `b` in semver order: MAJOR.MINOR.BUILD as
    /// numbers, then the build number, then when it came.
    static func newer(_ a: Build, than b: Build) -> Bool {
        func numbers(_ text: String) -> [Int] { text.split(separator: ".").map { Int($0) ?? 0 } }
        let (x, y) = (numbers(a.version), numbers(b.version))
        if x != y { return y.lexicographicallyPrecedes(x) }
        let (m, n) = (Int(a.buildNumber) ?? 0, Int(b.buildNumber) ?? 0)
        if m != n { return m > n }
        return a.published > b.published
    }
}
