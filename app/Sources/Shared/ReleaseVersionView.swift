import ApplicationsProtocol
import SwiftUI

/// A version of an app: its channels, every build of it for this device
/// (newest first, each bundle and kind apart, each with Install, opening to
/// its notes), what it has on every platform, and its notes.
struct ReleaseVersionView: View {
    @Environment(ApplicationsStore.self) private var store
    let app: String
    let version: String

    var body: some View {
        if let builds = store.app(app)?.builds.filter({ $0.version == version }), !builds.isEmpty {
            Form {
                Section {
                    HStack {
                        Text("\(app) \(version)").font(.title2.weight(.bold))
                        ForEach(Self.channels(builds), id: \.self) { ChannelBadge(channel: $0) }
                    }
                }
                ForEach(store.versionBuilds(app: app, version: version), id: \.latest?.id) { group in
                    Section {
                        ForEach(group.builds) { build in
                            NavigationLink(value: ApplicationsRoute.build(build.id)) {
                                BuildRow(build: build, builds: store.group(of: build) ?? group, channel: build.channel ?? .beta)
                            }
                        }
                    } header: {
                        Text("\(group.name) for this \(DeviceInstalls.deviceName)")
                    }
                }
                Section("On Every Platform") {
                    ForEach(Array(Set(builds.map(\.platform))).sorted(), id: \.self) { platform in
                        LabeledContent(PlatformName.title(platform),
                                       value: Self.newestPerBundle(builds.filter { $0.platform == platform })
                                           .map { "\($0.name) \($0.versionTitle)" }.joined(separator: ", "))
                    }
                }
                if let notes = builds.first?.notes, !notes.isEmpty {
                    NotesSections(notes: ReleaseNotes(notes))
                }
            }
            .groupedPage()
            .navigationTitle(version)
            .refreshable { await store.refresh() }
        } else {
            ContentUnavailableView("No such version", systemImage: "questionmark")
        }
    }

    /// Its builds' channels, production's first: a version can have both
    /// (a commit's beta, and its release).
    private static func channels(_ builds: [Build]) -> [ReleaseChannel] {
        [.production, .beta].filter { channel in builds.contains { ($0.channel ?? .beta) == channel } }
    }

    private static func newestPerBundle(_ builds: [Build]) -> [Build] {
        var seen = Set<String>()
        return builds.sorted { $0.published > $1.published }.filter { seen.insert($0.bundleID).inserted }
    }
}
