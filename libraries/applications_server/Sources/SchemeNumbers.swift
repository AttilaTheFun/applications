import ApplicationsProtocol
import Foundation

/// The build schemes' numbers given out (BuildSchemes), in schemes.json
/// beside the builds: each release's next number and whom each went to (an
/// app's bundle id, and the commit built), and the newest release of
/// Applications published here. A number goes to one app's build and never
/// to another's: a phone keeps an old build's scheme for as long as it
/// keeps the build, and the pool of 25 schemes this replaced, which gave a
/// scheme out again once a newer build freed it, made one app look
/// installed when a stale install of another still carried it.
struct SchemeNumbers: Codable, Equatable {
    /// A number given to an app's build of a commit; nil for a build that
    /// named no commit (given by hand before production was CI's alone).
    struct Given: Codable, Equatable {
        var number: Int
        var bundleID: String
        var commit: String?
    }

    /// A release's numbers: the next to give, and those given, in order.
    struct Release: Codable, Equatable {
        var next = 1
        var given: [Given] = []
    }

    /// The newest release of Applications published here, by number (a
    /// branch's build of an older one does not take it back); nil before
    /// the first.
    var applications: String?
    var releases: [String: Release] = [:]

    /// Why an app's build gets no number: its release's are given out.
    struct UsedUp: Error, CustomStringConvertible {
        let release: String
        var description: String {
            "All \(BuildSchemes.othersLimit) build schemes of Applications \(release) are given out: publish an Applications build of a newer "
                + "release (its version's MAJOR.MINOR past \(release)) to start that release's"
        }
    }

    static func load(_ file: URL) -> SchemeNumbers {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SchemeNumbers.self, from: $0) } ?? SchemeNumbers()
    }

    func save(_ file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    /// Changes the numbers with schemes.json locked, and keeps them if they
    /// changed: the running server and `applications-server scheme` on its
    /// Mac both give numbers out, and two processes reading the same next
    /// number would give it twice. Nothing is kept when `change` throws.
    static func update<T>(_ file: URL, _ change: (inout SchemeNumbers) throws -> T) throws -> T {
        // A lock file of its own: schemes.json is replaced whole on each save.
        let lock = open(file.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: file.path + ".lock"]) }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }
        let before = load(file)
        var numbers = before
        let result = try change(&numbers)
        if numbers != before { try numbers.save(file) }
        return result
    }

    /// A number for an app's build under a release: the one its commit was
    /// given before (a sha, or the start of one), else the next, which is
    /// `fresh`. Nil when the release's are given out.
    mutating func reserve(release: String, bundleID: String, commit: String?) -> (number: Int, fresh: Bool)? {
        var numbers = releases[release] ?? Release()
        if let commit, let given = numbers.given.first(where: { given in
            given.bundleID == bundleID && given.commit.map { $0.hasPrefix(commit) || commit.hasPrefix($0) } == true
        }) {
            return (given.number, false)
        }
        guard numbers.next <= BuildSchemes.othersLimit else { return nil }
        let number = numbers.next
        numbers.next += 1
        numbers.given.append(Given(number: number, bundleID: bundleID, commit: commit))
        releases[release] = numbers
        return (number, true)
    }

    /// A number just given that no build carries after all (signing the
    /// build again failed), given back if none was given after it.
    mutating func giveBack(release: String, number: Int) {
        guard var numbers = releases[release], numbers.next == number + 1, numbers.given.last?.number == number else { return }
        numbers.given.removeLast()
        numbers.next = number
        releases[release] = numbers
    }

    /// Whether a release's number went to an app's builds.
    func gave(release: String, number: Int, to bundleID: String) -> Bool {
        releases[release]?.given.contains { $0.number == number && $0.bundleID == bundleID } == true
    }

    /// Applications published at a release: the server's from now on, if
    /// it is newer than the one it had.
    mutating func published(applications release: String) {
        if applications.map({ ApplicationsServer.newer(release, $0) }) ?? true { applications = release }
    }
}
