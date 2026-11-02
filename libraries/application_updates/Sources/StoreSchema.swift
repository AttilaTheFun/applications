import Foundation
import SwiftSQL

/// The shared database's tables, made and moved on by numbered migrations:
/// SQLite's `user_version` says how many have run. Migrations only add
/// (tables, columns), so an app built before a migration reads and writes
/// a database that has it; one is never changed once released.
enum StoreSchema {
    static let migrations: [String] = [
        // 1: the apps, by bundle id (a beta's is a row of its own), and the
        // Mac's install requests, one a bundle id. Times are seconds since
        // 1970.
        """
        CREATE TABLE apps (
            bundle_id TEXT PRIMARY KEY NOT NULL,
            latest_version TEXT,
            latest_build TEXT,
            install_url TEXT,
            installed_version TEXT,
            installed_build TEXT,
            updated_at REAL NOT NULL
        );
        CREATE TABLE requests (
            bundle_id TEXT PRIMARY KEY NOT NULL,
            version TEXT NOT NULL,
            build TEXT,
            requested_by TEXT NOT NULL,
            requested_at REAL NOT NULL
        );
        """,
        // 2: the installed build's variant (its Info.plist's BuildVariant:
        // Alpha, Beta, AdHoc, Production), written with its version, as one
        // bundle id is one app installed at a time, whichever it is.
        """
        ALTER TABLE apps ADD COLUMN installed_variant TEXT;
        """,
    ]

    /// Write-ahead logging, so one app reads while another writes (the mode
    /// stays with the file), then the migrations this database lacks, in
    /// one transaction that takes the write lock first: of two processes
    /// opening a new database at once, one makes the tables and the other
    /// finds them made.
    static func prepare(_ connection: Connection) throws {
        try writeAheadLog(connection)
        try connection.execute("PRAGMA synchronous = NORMAL")
        try connection.transaction(.immediate) { connection in
            let version = try connection.query("PRAGMA user_version") { $0.int(0) }.first ?? 0
            guard version < migrations.count else { return }
            for migration in migrations[version...] { try connection.execute(migration) }
            try connection.execute("PRAGMA user_version = \(migrations.count)")
        }
    }

    /// Write-ahead logging, unless the file has it already. Switching takes
    /// the whole file, and SQLite answers busy at once there (the busy
    /// timeout is not asked, as Apple's SQLite shows when two processes
    /// open a new database together), so a busy switch is tried again for
    /// up to five seconds; the other process has usually switched it by then.
    static func writeAheadLog(_ connection: Connection) throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            do {
                if try mode(connection, "PRAGMA journal_mode") == "wal" { return }
                // Answers the mode it is in after: still the old one when
                // another connection held the file.
                if try mode(connection, "PRAGMA journal_mode = WAL") == "wal" { return }
                guard ContinuousClock.now < deadline else {
                    throw SQLiteError(extendedCode: 5 /* SQLITE_BUSY */, message: "the database could not be put in write-ahead-log mode")
                }
            } catch let error as SQLiteError where error.isBusy && ContinuousClock.now < deadline {
                // Busy: tried again below.
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func mode(_ connection: Connection, _ sql: String) throws -> String? {
        try connection.query(sql) { $0.text(0) }.first??.lowercased()
    }
}
