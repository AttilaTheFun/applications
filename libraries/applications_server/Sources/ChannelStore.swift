import ApplicationsProtocol
import Foundation

/// Each app's versions' channels, kept in channels.json from before builds
/// had a channel of their own, when a version was promoted to production
/// whole: what a build from then is (one that says no channel). Read only:
/// nothing adds to it now. "alpha", as beta was named then, reads as beta.
public struct ChannelStore: Sendable {
    struct Entry: Codable, Sendable, Equatable {
        var channel: ReleaseChannel
        var promoted: Date?
        /// The commit it was released from.
        var commit: String?
    }

    let file: URL

    public init(file: URL) { self.file = file }

    func all() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    static func key(_ app: String, _ version: String) -> String { app + "\u{1F}" + version }

    /// The channels as they are now, read once, to say what many builds are.
    func snapshot(names: [String: String]) -> Snapshot { Snapshot(entries: all(), names: names) }

    struct Snapshot {
        let entries: [String: Entry]
        let names: [String: String]

        /// A build's channel: its own; else, for a build from before builds
        /// had one, its version's (every build of a version in production
        /// is, as it was kept for good then).
        func channel(of build: Build) -> ReleaseChannel {
            build.channel ?? entries[ChannelStore.key(build.identity(names), build.version)]?.channel ?? .beta
        }
    }
}
