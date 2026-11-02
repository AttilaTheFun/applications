import ApplicationsProtocol
import SwiftUI

/// A build in an app's list: its numbers, channel and whether it is the
/// newest, when it came, and its notes' first line; and Install, Update or
/// Open.
struct BuildRow: View {
    let build: Build
    let builds: AppBuilds
    /// Its channel, where builds of both are shown together; nil where they
    /// are apart, or for a pull request's build, which show its commit
    /// instead.
    let channel: ReleaseChannel?
    /// Its variant (Alpha, Beta, Production, AdHoc) beside when it came,
    /// where builds of every variant are shown together: on the second line,
    /// so the first keeps its numbers whole on a phone.
    var showsVariant = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(build.versionTitle).font(.headline).lineLimit(1)
                    if let channel {
                        ChannelBadge(channel: channel)
                    } else if let commit = build.origin?.commit {
                        Text(commit.prefix(7))
                            .font(.caption2.monospaced().weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(.secondary)
                            .background(.quaternary, in: Capsule())
                            .fixedSize()
                    }
                    if build.id == builds.latest?.id { LatestBadge() }
                }
                HStack(spacing: 6) {
                    if showsVariant { ChannelBadge(build: build) }
                    Text(build.published, format: .relative(presentation: .named)).font(.subheadline).foregroundStyle(.secondary)
                }
                let summary = ReleaseNotes(build.notes).summary
                if !summary.isEmpty {
                    Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            BuildInstallButton(builds: builds, build: build)
        }
        .padding(.vertical, 2)
    }
}
