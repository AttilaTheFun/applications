import Foundation

/// A database file of a test's own, in a folder removed with it.
struct TemporaryDatabase {
    let folder: URL
    var file: URL { folder.appendingPathComponent("updates.sqlite") }

    init() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("application-updates-" + UUID().uuidString, isDirectory: true)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
}
