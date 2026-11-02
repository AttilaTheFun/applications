import ApplicationsProtocol
import SwiftUI

/// One app on this device: its latest Alpha, Beta and Production at the top
/// (each opening to its version), then every build in semver order (each
/// opening to the build), and its pull requests' builds.
struct AppBuildsView: View {
    @Environment(ApplicationsStore.self) private var store
    let bundleID: String

    var body: some View {
        Form {
            if let listing = store.listing(bundleID: bundleID) {
                let all = Self.everyBuild(listing.groups)
                Section {
                    ForEach(Self.latestOfEachVariant(all), id: \.build.id) { builds, build in
                        NavigationLink(value: ApplicationsRoute.version(listing.app.app, build.version)) {
                            BuildRow(build: build, builds: builds, channel: nil, showsVariant: true)
                        }
                    }
                } header: {
                    Text("Latest")
                }
                Section {
                    ForEach(all, id: \.build.id) { builds, build in
                        NavigationLink(value: ApplicationsRoute.build(build.id)) {
                            BuildRow(build: build, builds: builds, channel: nil, showsVariant: true)
                        }
                    }
                } header: {
                    Text("All builds")
                } footer: {
                    Text("Alphas and AdHoc builds are kept a week, Betas two weeks, Production for good; the newest Alpha, Beta and Production are always kept.")
                }
                ForEach(store.pullRequestBuilds(listing), id: \.0.number) { pullRequest, groups in
                    Section {
                        ForEach(groups, id: \.bundleID) { builds in
                            ForEach(builds.builds) { build in
                                NavigationLink(value: ApplicationsRoute.build(build.id)) {
                                    BuildRow(build: build, builds: builds, channel: nil)
                                }
                            }
                        }
                    } header: {
                        Text("Pull request #\(pullRequest.number)" + (pullRequest.branch.map { " · \($0)" } ?? ""))
                    }
                }
            } else {
                Text(store.isRefreshing ? "Asking the server…" : "This app has no builds for this device.")
                    .foregroundStyle(.secondary)
            }
        }
        .groupedPage()
        .navigationTitle(store.listing(bundleID: bundleID)?.name ?? "Builds")
        .refreshable { await store.refresh() }
    }

    /// Every build of the app on this device, with the builds it is
    /// installed among, in semver order, newest first.
    static func everyBuild(_ groups: [AppBuilds]) -> [(builds: AppBuilds, build: Build)] {
        groups.flatMap { builds in builds.builds.filter { $0.origin?.pullRequest == nil }.map { (builds: builds, build: $0) } }
            .sorted { BuildVariants.newer($0.build, than: $1.build) }
    }

    /// The newest Alpha, Beta and Production, those there are, in that order.
    static func latestOfEachVariant(_ all: [(builds: AppBuilds, build: Build)]) -> [(builds: AppBuilds, build: Build)] {
        BuildVariants.order.compactMap { variant in all.first { BuildVariants.variant(of: $0.build) == variant } }
    }
}
