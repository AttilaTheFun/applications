/// The running app's check, at launch and whenever it comes to the
/// foreground or the database changes: its installed build written to the
/// shared database, then, when Applications knows of a newer one, the user
/// told, once a newer build a process, and only while the app is in the
/// foreground. An actor: the database is read and written off the main
/// actor.
public actor UpdateChecker {
    public let store: AppGroupStore
    public let app: InstalledApp
    private let presenter: any UpdatePresenter
    /// Whether the user is told at all: Applications writes its own
    /// installed build, but tells of its updates itself.
    private let tells: Bool
    /// The updates told of in this process.
    private var told: Set<String> = []

    public init(store: AppGroupStore, app: InstalledApp, presenter: any UpdatePresenter, tells: Bool = true) {
        self.store = store
        self.app = app
        self.presenter = presenter
        self.tells = tells
    }

    /// Writes the installed build and decides; tells the user of an update
    /// not told of yet when the app is in the foreground.
    @discardableResult
    public func check() async throws -> UpdateCheck {
        try await store.recordInstalled(bundleID: app.bundleID, version: app.version, build: app.build, variant: app.variant)
        let found = UpdateCheck.decide(record: try await store.record(bundleID: app.bundleID), installed: app)
        guard tells, case .available(let update) = found, !told.contains(update.key) else { return found }
        // Marked before the waits, so a check that overlaps this one does
        // not tell it again; unmarked if the app is not in the foreground.
        told.insert(update.key)
        guard await presenter.isInForeground() else {
            told.remove(update.key)
            return found
        }
        await presenter.present(update)
        return found
    }
}
