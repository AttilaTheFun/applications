import ApplicationsProtocol
import Foundation

/// The build numbers CI has given commits, kept in build-numbers.json: one
/// per app, version and commit, so a commit's number is the same however
/// often it is asked, and a number given is never given again.
public struct BuildNumberStore: Sendable {
    let file: URL

    public init(file: URL) { self.file = file }

    public func all() -> [BuildNumber] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([BuildNumber].self, from: data)) ?? []
    }

    /// Those of a commit (its sha, or the start of it).
    public func of(commit: String) -> [BuildNumber] {
        all().filter { $0.commit.hasPrefix(commit) || commit.hasPrefix($0.commit) }
    }

    public func keep(_ number: BuildNumber) {
        var numbers = all()
        numbers.removeAll { $0.app == number.app && $0.version == number.version && $0.commit == number.commit }
        numbers.append(number)
        // The latest few hundred: enough to cover every commit still built.
        try? save(Array(numbers.suffix(500)))
    }

    func save(_ numbers: [BuildNumber]) throws {
        try JSONEncoder().encode(numbers).write(to: file, options: .atomic)
    }
}
