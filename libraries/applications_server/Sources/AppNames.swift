import Foundation

/// Which app a bundle id's builds are builds of, where its own name does
/// not say (an Android build of "Visor Lite" whose launcher label is
/// "Visor"), kept in apps.json: `applications-server app <bundle id> <app>`.
public struct AppNames: Sendable {
    let file: URL

    public init(file: URL) { self.file = file }

    public func all() -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// The app a bundle id belongs to; "" takes the mapping away.
    public func set(_ app: String, for bundleID: String) {
        var names = all()
        names[bundleID] = app.isEmpty ? nil : app
        try? save(names)
    }

    func save(_ names: [String: String]) throws {
        try JSONEncoder().encode(names).write(to: file, options: .atomic)
    }

    /// The app named by a release notes' marker, `<!-- app: Visor Lite -->`
    /// on a line of its own (how an inbox upload names its app), and the
    /// notes without it.
    public static func marker(in notes: String) -> (app: String?, notes: String) {
        var app: String?
        let lines = notes.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->") else { return true }
            let inner = trimmed.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
            guard inner.lowercased().hasPrefix("app:") else { return true }
            app = inner.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return false
        }
        return (app.flatMap { $0.isEmpty ? nil : $0 }, lines.joined(separator: "\n").trimmingCharacters(in: .newlines))
    }
}
