/// What a check found of the running app.
public enum UpdateCheck: Sendable, Equatable {
    /// Applications has said nothing of the app yet.
    case unknown
    /// The installed build is the newest, or newer.
    case upToDate
    case available(AvailableUpdate)

    /// The decision, from the app's row and what is running.
    public static func decide(record: AppRecord?, installed: InstalledApp) -> UpdateCheck {
        guard let record, let latest = record.latest else { return .unknown }
        guard latest > installed.appVersion else { return .upToDate }
        return .available(AvailableUpdate(bundleID: installed.bundleID, version: latest.version, build: latest.build,
                                          installURL: record.installURL, installedVersion: installed.version,
                                          installedBuild: installed.build))
    }
}
