import Foundation

/// The server's connection code, on the web: in the page's own storage
/// (UserDefaults, kept in the origin's IndexedDB), the only place a browser
/// has. The page is served by the server it names, at its own origin, so
/// only that server's pages read it. "" removes it.
enum Keychain {
    static func get(_ account: String) -> String {
        UserDefaults.standard.string(forKey: key(account)) ?? ""
    }

    static func set(_ account: String, _ value: String) {
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(account))
        } else {
            UserDefaults.standard.set(value, forKey: key(account))
        }
    }

    private static func key(_ account: String) -> String { "secret." + account }
}
