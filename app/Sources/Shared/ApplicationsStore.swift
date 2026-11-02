import ApplicationUpdates
import ApplicationsProtocol
import Foundation
import Observation
import PipelineClient

/// What Applications knows: the server (`connection`), every app it
/// has with its builds on their channels, what is installed here
/// (`DeviceInstalls`), and the app open.
@MainActor
@Observable
final class ApplicationsStore {
    static let shared = ApplicationsStore()

    /// This app's link scheme, as its Info.plist declares it: `applications`,
    /// for every build (Alpha, Beta, Production: docs/VARIANTS.md).
    static let linkScheme: String = {
        let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return types.lazy.compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }.first ?? "applications"
    }()

    let connection = ServerConnection(serverName: "Applications Server", kind: "applications", scheme: ApplicationsStore.linkScheme)
    private(set) var apps: [AppRelease] = []
    /// The refresh under way.
    private var refreshing: Task<Void, Never>?
    var isRefreshing: Bool { refreshing != nil }
    /// Why an install did not go through.
    var failure: String?
    /// The app open (its production bundle id: its row's), and the way in
    /// past its builds.
    var selection: String?
    var path: [ApplicationsRoute] = []
    /// The settings (the server), shown at once while there is none.
    var showingSettings = false
    /// Whether this device trusts the server's certificate authority on its
    /// own (what installing over the air needs on an iPhone); nil until the
    /// server has been reached.
    private(set) var systemTrusts: Bool?
    let installs = DeviceInstalls()
    /// The database Applications shares with the apps it distributes
    /// (ApplicationUpdates): each app's newest build, written after each sync
    /// (UpdateFeed), and on a Mac the apps' install requests
    /// (InstallRequests). Nil without the app group's container.
    let updates: AppGroupStore? = try? AppGroupStore.appGroup()
    /// Showing the fixture (ApplicationsFixture): no server is asked.
    private(set) var showsFixture = false

    private var pushToken: (token: String, environment: String, name: String)?
    private var icons: [String: Data] = [:]
    private static let catalogKey = "catalog"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.catalogKey),
           let apps = try? WireCoding.decoder().decode([AppRelease].self, from: data) {
            self.apps = apps
        }
        installs.refresh(apps.flatMap(appBuilds))
        showingSettings = connection.code == nil
        connection.networkChanged = { [weak self] in Task { await self?.refresh() } }
        // An app, a version or the settings opened at launch, for a look in a
        // simulator: `-applications.install <bundle id>`,
        // `-applications.version <version>` (of that app),
        // `-applications.settings YES`.
        if let bundleID = UserDefaults.standard.string(forKey: "applications.install"), !bundleID.isEmpty {
            selection = BundleVariant.productionID(bundleID)
            if let version = UserDefaults.standard.string(forKey: "applications.version"), !version.isEmpty,
               let app = listing(bundleID: bundleID)?.app.app {
                path = [.version(app, version)]
            }
        }
        if UserDefaults.standard.bool(forKey: "applications.settings") { showingSettings = true }
        if UserDefaults.standard.bool(forKey: "applications.fixture") { showFixture() }
    }

    /// The fixture instead of a server's (ApplicationsFixture).
    func showFixture() {
        showsFixture = true
        apps = ApplicationsFixture.apps
        showingSettings = false
    }

    var code: ConnectionCode? { connection.code }
    var problem: String? { connection.problem }
    var platform: String { DeviceInstalls.platform }

    func app(_ name: String) -> AppRelease? { apps.first { $0.app == name } }

    /// The apps list's rows: each app's bundles on this device, one row
    /// each, its beta with its production (an app with nothing for this
    /// device has none), by name.
    var listings: [AppListing] {
        apps.flatMap { AppListing.rows($0, builds: $0.builds(on: platform)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The row of a bundle's builds on this device (a beta's is its
    /// production's).
    func listing(bundleID: String) -> AppListing? {
        let id = BundleVariant.productionID(bundleID)
        return listings.first { $0.id == id }
    }

    /// A build on this device, by id: main's, a release's or a pull request's.
    func build(_ id: String) -> Build? { allBuilds.first { $0.id == id } }

    /// Every build for this device: main's and releases', and the open
    /// pull requests'.
    private var allBuilds: [Build] {
        apps.flatMap { app in app.builds(on: platform) + (app.pullRequests ?? []).flatMap { $0.builds.filter { $0.platform == platform } } }
    }

    /// The builds a build is installed among (of its bundle id and kind:
    /// main's and releases', or its pull request's), which say whether it
    /// is installed here.
    func group(of build: Build) -> AppBuilds? {
        for app in apps {
            let pullRequests = (app.pullRequests ?? []).flatMap { AppListing.byBundle($0.builds.filter { $0.platform == platform }) }
            if let found = (appBuilds(app) + pullRequests).first(where: { $0.builds.contains { $0.id == build.id } }) { return found }
        }
        return nil
    }

    /// One version's builds on this device, each bundle and kind apart
    /// (newest first), production's first.
    func versionBuilds(app name: String, version: String) -> [AppBuilds] {
        guard let app = app(name) else { return [] }
        return AppListing.rows(app, builds: app.builds(on: platform).filter { $0.version == version }).flatMap(\.groups)
    }

    /// A row's pull requests' builds on this device (newest first), each
    /// pull request apart, by bundle.
    func pullRequestBuilds(_ listing: AppListing) -> [(PullRequestRelease, [AppBuilds])] {
        (listing.app.pullRequests ?? []).compactMap { pullRequest in
            let groups = AppListing.byBundle(pullRequest.builds.filter { $0.platform == platform && $0.productionBundleID == listing.id })
            return groups.isEmpty ? nil : (pullRequest, groups)
        }
    }

    /// The app's builds for this device, by bundle id and kind (an app can
    /// have more than one bundle here: Visor and Visor Server on a Mac, and
    /// each one's beta), newest first.
    func appBuilds(_ app: AppRelease) -> [AppBuilds] {
        AppListing.rows(app, builds: app.builds(on: platform)).flatMap(\.groups)
    }

    // MARK: The server

    /// Takes a pasted code and asks the server: nil when it is one, else why not.
    func connect(_ text: String) async -> String? {
        if let problem = connection.connect(text) { return problem }
        apps = []
        systemTrusts = nil
        await refresh()
        // Another server's code: not kept, and why.
        if let wrong = connection.wrongServer {
            connection.forget()
            return wrong
        }
        if connection.problem == nil { showingSettings = false }
        return nil
    }

    /// A connection link (`applications://connect?code=…`, what the QR code
    /// `applications-server code --qr` makes says): its server connected.
    func open(link url: URL) {
        if url.scheme == connection.scheme, url.host() == "build" {
            return open(buildLink: url)
        }
        guard let text = connection.code(in: url) else { return }
        Task { if let problem = await connect(text) { failure = problem } }
    }

    /// A build's link (`applications://build?id=…`, or `?commit=…&app=…`, a
    /// commit's build of an app): its page here.
    private func open(buildLink url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        Task {
            await refresh()
            let app = value("app")
            let build = value("id").flatMap { self.build($0) } ?? value("commit").flatMap { commit in
                allBuilds.filter { candidate in
                    (candidate.origin?.commit ?? "").hasPrefix(commit) && (app == nil || candidate.app == app)
                }.max { $0.published < $1.published }
            }
            guard let build else {
                failure = "No build of that here: it may not be built yet (:build:), or not for this device."
                return
            }
            selection = build.productionBundleID
            path = [.build(build.id)]
        }
    }

    func forget() {
        connection.forget()
        UserDefaults.standard.removeObject(forKey: Self.catalogKey)
        apps = []
        systemTrusts = nil
        selection = nil
        path = []
        showingSettings = true
    }

    /// The page on the server's plain port that offers its certificate
    /// authority's profile, for Safari.
    var profileURL: URL? {
        guard let address = connection.address ?? code?.addresses.first else { return nil }
        return ServerClient.profileURL(for: address)
    }

    /// Every app again, from whichever path answers. One at a time:
    /// a refresh asked for while one is under way waits for it. It runs on
    /// its own, not as part of whatever asked (a window's task, which a
    /// background launch can end at once), so its requests are not cut off.
    func refresh() async {
        guard !showsFixture else { return }
        if let running = refreshing {
            await running.value
            return
        }
        let running = Task { await reload() }
        refreshing = running
        await running.value
        refreshing = nil
    }

    private func reload() async {
        guard connection.client != nil else { return }
        guard await connection.choosePath() != nil else { return }
        do {
            apps = try await connection.ask { try await $0.get([AppRelease].self, "/api/catalog", at: $1) }
            connection.problem = nil
            systemTrusts = connection.client?.pinning.systemTrusts
            if let data = try? WireCoding.encoder().encode(apps) { UserDefaults.standard.set(data, forKey: Self.catalogKey) }
            tellApps()
            if let pushToken, let (client, address) = await connection.reachable() { await register(pushToken, client: client, at: address) }
        } catch {
            connection.problem = error.localizedDescription
        }
        installs.refresh(apps.flatMap(appBuilds))
    }

    /// Each app's newest build here to the database the apps read
    /// (UpdateFeed); the apps running told when it moved.
    private func tellApps() {
        guard let updates, let address = connection.address else { return }
        let latest = UpdateFeed.latest(apps.flatMap(appBuilds), address: address)
        Task {
            do {
                if try await updates.setLatest(latest) { UpdateSignal().post() }
            } catch {
                NSLog("Applications: the apps' newest builds were not written: %@", String(describing: error))
            }
        }
    }

    // MARK: Installing

    /// Installs a build here: nil when it is on its way or in place, else why not.
    func install(_ build: Build) async -> String? {
        // Chosen afresh for each install: the link handed to iOS must be one
        // it reaches from here.
        guard let address = await connection.choosePath(), let client = connection.client else { return connection.unreachable }
        let failure = await installs.install(build, client: client, address: address)
        installs.refresh(apps.flatMap(appBuilds))
        return failure
    }

    /// A build's icon; kept once fetched.
    func icon(build: String) async -> Data? {
        if let known = icons[build] { return known }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("icons")
        let file = folder.appendingPathComponent(build + ".png")
        if let data = try? Data(contentsOf: file) {
            icons[build] = data
            return data
        }
        guard let data = try? await connection.ask({ client, address in try await client.data("/api/builds/\(build)/icon", at: address) }) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file)
        icons[build] = data
        return data
    }

    // MARK: Pushes

    /// The system gave a push token: the server is told, now if it is
    /// reached, else on the next refresh.
    func didRegister(token: String, environment: String, name: String) {
        pushToken = (token, environment, name)
        Task {
            guard let (client, address) = await connection.reachable() else { return }
            await register((token, environment, name), client: client, at: address)
        }
    }

    private func register(_ push: (token: String, environment: String, name: String), client: ServerClient, at address: String) async {
        let device = DeviceRegistration(token: push.token, environment: push.environment, topic: Bundle.main.bundleIdentifier ?? "",
                                        name: push.name)
        try? await client.post(device, to: "/api/devices", at: address)
    }

    /// A notification about a build was opened: the build, installed at
    /// once when Install was chosen on it.
    func open(build id: String, installing: Bool) {
        Task {
            await refresh()
            guard let build = self.build(id) else { return }
            selection = build.productionBundleID
            path = [.build(build.id)]
            if installing, let failure = await install(build) { self.failure = failure }
        }
    }
}
