import Foundation
import PipelineServer

/// Builds left by agents on other computers, which cannot reach the server
/// themselves without its password: each uploads `<name>.ipa` (or a Mac
/// app's `<name>.zip` or `.dmg`, or an Android app's `<name>.apk`), and
/// its release notes as `<name>.md`, to a draft release tagged "inbox" in a
/// private GitHub repository, and the server, which the `gh` here is signed
/// in to, takes them every minute — published, announced, and removed from
/// the inbox.
public struct InboxPoller: Sendable {
    let repository: String
    let gh: String
    let scratch: URL

    public static let tag = "inbox"

    /// Nil when there is no `gh` to ask with.
    public init?(repository: String, scratch: URL) {
        guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return nil
        }
        self.repository = repository
        self.gh = gh
        self.scratch = scratch
    }

    /// What the inbox holds: builds, with their notes' asset when there is one.
    struct Waiting: Equatable {
        var build: String
        var notes: String?
    }

    static func waiting(in assets: [String]) -> [Waiting] {
        assets.filter { name in [".ipa", ".zip", ".dmg", ".apk"].contains { name.hasSuffix($0) } }.sorted().map { name in
            let notes = String(name.dropLast(4)) + ".md"
            return Waiting(build: name, notes: assets.contains(notes) ? notes : nil)
        }
    }

    /// Takes what is waiting, every minute, until the task is cancelled.
    /// A build that cannot be published is left where it is and said once.
    public func run(publish: @escaping @Sendable (URL, String) async throws -> Void) async {
        var refused: Set<String> = []
        var reading: Bool?
        while !Task.isCancelled {
            let names: [String]
            do {
                names = try assets()
                if reading != true { FileHandle.standardError.write(Data("applications-server: watching \(repository)'s inbox\n".utf8)) }
                reading = true
            } catch {
                if reading != false { FileHandle.standardError.write(Data("applications-server: \(repository)'s inbox cannot be read: \(error)\n".utf8)) }
                reading = false
                names = []
            }
            for item in Self.waiting(in: names) where !refused.contains(item.build) {
                do {
                    try await take(item, publish: publish)
                } catch {
                    refused.insert(item.build)
                    FileHandle.standardError.write(Data("applications-server: the inbox's \(item.build) was not published: \(error)\n".utf8))
                }
            }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    private func take(_ item: Waiting, publish: @Sendable (URL, String) async throws -> Void) async throws {
        let folder = scratch.appendingPathComponent("inbox-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = [item.build] + (item.notes.map { [$0] } ?? [])
        try ProcessRunner.run(gh, ["release", "download", Self.tag, "--repo", repository, "--dir", folder.path]
                              + names.flatMap { ["--pattern", $0] })
        let notes = item.notes.flatMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) } ?? ""
        try await publish(folder.appendingPathComponent(item.build), notes)
        for name in names { _ = try? ProcessRunner.run(gh, ["release", "delete-asset", Self.tag, name, "--repo", repository, "--yes"]) }
        FileHandle.standardError.write(Data("applications-server: published \(item.build) from the inbox\n".utf8))
    }

    private func assets() throws -> [String] {
        let data = try ProcessRunner.run(gh, ["release", "view", Self.tag, "--repo", repository, "--json", "assets"])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["assets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }
}
