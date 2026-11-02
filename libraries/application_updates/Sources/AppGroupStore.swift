import Foundation
import SwiftSQL

/// The database Applications and the apps it distributes share, in their
/// app group's container: each app's newest build, which Applications
/// writes, and the build installed, which each app writes of itself
/// (`AppRecord`); and, on a Mac, the apps' install requests to
/// Applications (`InstallRequest`).
///
/// Several processes use it at once: SQLite in write-ahead-log mode, a busy
/// timeout for another's write, and a connection opened for each call and
/// closed after it. None is held open, so no lock on a file in the shared
/// container is held while an iPhone app is suspended, which iOS ends the
/// app for (0xdead10cc); opening one costs less than the launch it serves.
public actor AppGroupStore {
    /// The app group of Applications and the apps it distributes.
    public static let applicationsAppGroup = "group.com.LoganShire.Applications"
    /// The database's name in the group's container.
    public static let fileName = "ApplicationUpdates.sqlite"

    public let fileURL: URL
    private let now: @Sendable () -> Date
    /// The tables made in this process already.
    private var prepared = false

    /// The database at `fileURL`, made on first use. `now` is when a write
    /// happens (tests fix it).
    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    #if canImport(Darwin)
    /// The database in an app group's container (Applications' by default).
    /// Throws when the app has no such container: its entitlements and
    /// profile don't grant the group.
    public static func appGroup(_ identifier: String = applicationsAppGroup) throws -> AppGroupStore {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw AppGroupStoreError.noContainer(appGroup: identifier)
        }
        return AppGroupStore(fileURL: container.appendingPathComponent(fileName))
    }
    #endif

    // MARK: Apps

    /// The app's installed build, its version and its variant, written when
    /// it differs from what the row says (another variant of the same
    /// version too: the last launched is the one installed): whether it did.
    @discardableResult
    public func recordInstalled(bundleID: String, version: String, build: String?, variant: String? = nil) throws -> Bool {
        try withConnection { connection in
            try connection.run("""
                INSERT INTO apps (bundle_id, installed_version, installed_build, installed_variant, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)
                ON CONFLICT (bundle_id) DO UPDATE SET installed_version = excluded.installed_version,
                    installed_build = excluded.installed_build, installed_variant = excluded.installed_variant,
                    updated_at = excluded.updated_at
                WHERE installed_version IS NOT excluded.installed_version OR installed_build IS NOT excluded.installed_build
                    OR installed_variant IS NOT excluded.installed_variant
                """, bundleID, version, build, variant, now().timeIntervalSince1970) > 0
        }
    }

    /// The newest builds, as Applications synced them, each written where it
    /// differs, in one transaction: whether any did.
    @discardableResult
    public func setLatest(_ builds: [LatestBuild]) throws -> Bool {
        let time = now().timeIntervalSince1970
        return try withConnection { connection in
            try connection.transaction(.immediate) { connection in
                var changed = false
                for build in builds {
                    let rows = try connection.run("""
                        INSERT INTO apps (bundle_id, latest_version, latest_build, install_url, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)
                        ON CONFLICT (bundle_id) DO UPDATE SET latest_version = excluded.latest_version,
                            latest_build = excluded.latest_build, install_url = excluded.install_url, updated_at = excluded.updated_at
                        WHERE latest_version IS NOT excluded.latest_version OR latest_build IS NOT excluded.latest_build
                            OR install_url IS NOT excluded.install_url
                        """, build.bundleID, build.version, build.build, build.installURL?.absoluteString, time)
                    changed = changed || rows > 0
                }
                return changed
            }
        }
    }

    /// An app's row, or nil when neither it nor Applications has written one.
    public func record(bundleID: String) throws -> AppRecord? {
        try withConnection { connection in
            try connection.query("SELECT \(Self.columns) FROM apps WHERE bundle_id = ?1", bundleID, row: Self.record).first
        }
    }

    /// Every app's row, by bundle id.
    public func records() throws -> [AppRecord] {
        try withConnection { connection in
            try connection.query("SELECT \(Self.columns) FROM apps ORDER BY bundle_id", row: Self.record)
        }
    }

    // MARK: Install requests (the Mac)

    /// Asks Applications to install an app: replaces the app's earlier request.
    public func requestInstall(_ request: InstallRequest) throws {
        try withConnection { connection in
            try connection.run("""
                INSERT OR REPLACE INTO requests (bundle_id, version, build, requested_by, requested_at) VALUES (?1, ?2, ?3, ?4, ?5)
                """, request.bundleID, request.version, request.build, request.requestedBy, request.requestedAt.timeIntervalSince1970)
        }
    }

    /// Takes back an app's request (Applications could not be opened).
    public func cancelInstallRequest(bundleID: String) throws {
        try withConnection { connection in
            try connection.run("DELETE FROM requests WHERE bundle_id = ?1", bundleID)
        }
    }

    /// The requests waiting, oldest first, left in place.
    public func installRequests() throws -> [InstallRequest] {
        try withConnection { try Self.requests($0) }
    }

    /// The requests waiting, oldest first, taken: each goes to one taker,
    /// however many copies of Applications look at once.
    public func takeInstallRequests() throws -> [InstallRequest] {
        try withConnection { connection in
            try connection.transaction(.immediate) { connection in
                let taken = try Self.requests(connection)
                try connection.execute("DELETE FROM requests")
                return taken
            }
        }
    }

    // MARK: The connection

    /// Opens the database for `body` and closes it after; the tables made
    /// first, the first time in this process.
    @discardableResult
    private func withConnection<T>(_ body: (Connection) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try Database(path: fileURL.path)
        defer { database.close() }
        return try database.withConnection { connection in
            if !prepared {
                try StoreSchema.prepare(connection)
                prepared = true
            }
            return try body(connection)
        }
    }

    private static let columns = "bundle_id, latest_version, latest_build, install_url, installed_version, installed_build, updated_at, installed_variant"

    private static func record(_ row: Row) -> AppRecord {
        AppRecord(bundleID: row.text(0) ?? "", latestVersion: row.text(1), latestBuild: row.text(2),
                  installURL: row.text(3).flatMap(URL.init(string:)), installedVersion: row.text(4), installedBuild: row.text(5),
                  installedVariant: row.text(7), updatedAt: Date(timeIntervalSince1970: row.double(6)))
    }

    private static func requests(_ connection: Connection) throws -> [InstallRequest] {
        try connection.query("SELECT bundle_id, version, build, requested_by, requested_at FROM requests ORDER BY requested_at, bundle_id") { row in
            InstallRequest(bundleID: row.text(0) ?? "", version: row.text(1) ?? "", build: row.text(2), requestedBy: row.text(3) ?? "",
                           requestedAt: Date(timeIntervalSince1970: row.double(4)))
        }
    }
}
