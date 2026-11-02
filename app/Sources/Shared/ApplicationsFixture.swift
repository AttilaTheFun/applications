import ApplicationsProtocol
import Foundation

/// What Applications shows with no server: three apps with builds for this
/// device, each one entry in the list: one with a production build and its
/// beta's builds beside it, one with a beta alone, one with production
/// alone (an id with no `.Beta` beside it), every build with its commit,
/// for the snapshot tests and a look in a simulator
/// (`-applications.fixture YES`).
@MainActor
enum ApplicationsFixture {
    static var apps: [AppRelease] {
        let platform = DeviceInstalls.platform
        // An hour and a day ago, whenever it is shown.
        let hour = Date().addingTimeInterval(-3600), hours = Date().addingTimeInterval(-7200), day = Date().addingTimeInterval(-86_400)
        // As the server lists them: under their app's name, a beta from
        // main's commit, a release from its tag's.
        func build(_ id: String, _ bundleID: String, _ name: String, _ version: String, _ number: String, _ published: Date,
                   _ channel: ReleaseChannel, _ commit: String) -> Build {
            Build(id: id, bundleID: bundleID, name: name, version: version, buildNumber: number, platform: platform, published: published,
                  size: 8_200_000, notes: "What changed, and what to try.", app: BundleVariant.productionName(name, bundleID: bundleID),
                  origin: BuildOrigin(commit: commit, branch: channel == .beta ? "main" : nil), channel: channel)
        }
        return [
            AppRelease(app: "Visor", iconBuild: nil, builds: [
                build("visor-7", "com.example.Visor.Beta", "Visor β", "0.35", "7", hour, .beta, "7d3e9a1c40b2f6e85a1d0c93b7e4f2a6c8d1e5f0"),
                build("visor-6", "com.example.Visor.Beta", "Visor β", "0.35", "6", hours, .beta, "61c0b8e2d9a74f35c1e6b0a8d2f9c4e7b3a5d8f1"),
                build("visor-34", "com.example.Visor", "Visor", "0.34", "12", day, .production, "34a5f7c2e8d1b9046c3e7a2f5d8b1c4e9a0f6d27"),
            ]),
            AppRelease(app: "Noson", iconBuild: nil, builds: [
                build("noson-9", "com.example.Noson.Beta", "Noson β", "0.6", "9", hour, .beta, "9b2c4d6e8f0a1b3c5d7e9f1a2b4c6d8e0f2a4b6c"),
            ]),
            AppRelease(app: "Halo", iconBuild: nil, builds: [
                build("halo-21", "com.example.Halo", "Halo", "1.4", "21", day, .production, "21f4e6a8c0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0"),
            ]),
        ]
    }
}
