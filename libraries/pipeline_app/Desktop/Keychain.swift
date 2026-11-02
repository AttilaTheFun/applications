import Foundation

/// The server's connection code, on Linux and Windows: a file of its own in
/// the user's application data (~/.local/share/Applications on Linux,
/// readable by the user alone; %APPDATA%\Applications on Windows, the
/// user's own profile), as a desktop app keeps its secrets without a
/// keychain. "" removes it.
enum Keychain {
    static func get(_ account: String) -> String {
        (try? String(contentsOf: file(account), encoding: .utf8)) ?? ""
    }

    static func set(_ account: String, _ value: String) {
        let file = file(account)
        guard !value.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Made empty and closed to others before the secret goes in.
        _ = FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try? Data(value.utf8).write(to: file)
    }

    private static func file(_ account: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return support.appendingPathComponent("Applications", isDirectory: true).appendingPathComponent(account + ".secret")
    }
}
