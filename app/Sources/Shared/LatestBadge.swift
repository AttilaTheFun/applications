import SwiftUI

/// The newest build's mark, as a small capsule like the channel's.
struct LatestBadge: View {
    var body: some View {
        Text("Latest")
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}
