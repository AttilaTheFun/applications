import AppKit
import ApplicationsProtocol
import Foundation
import Observation
import PipelineClient

/// Installing on a Mac: a build downloaded and put in place in
/// Applications (MacInstall), and what is installed read from the apps
/// themselves (InstalledApps).
@MainActor
@Observable
final class DeviceInstalls {
    static let platform = "macos"
    /// The apps list's icons, on a Mac.
    static let iconSize: CGFloat = 44
    /// A sheet's least size: none on a phone (a sheet there is the screen's
    /// width, and one asked to be wider ran off it), a window's on a Mac.
    static let sheetMinimumWidth: CGFloat? = 420
    static let sheetMinimumHeight: CGFloat? = 420
    /// What this device is, in the apps list's words.
    static let deviceName = "Mac"
    /// What follows a build installed.
    static let handedOverWords = "It is in place in Applications."
    /// A Mac downloads builds itself, pinned to the server's authority.
    static let needsTrustedAuthority = false

    private(set) var installed: [String: InstalledBuild] = [:]
    /// The builds being downloaded and put in place.
    private(set) var installing: Set<String> = []

    /// Each bundle id's groups of builds (its Alpha's, Production's, …), as
    /// the last refresh had them: which holds the build installed is decided
    /// among them all, so one does.
    private var groups: [String: [AppBuilds]] = [:]

    /// Whether these builds hold the one installed of their bundle id: the
    /// group AppBuilds.holder picks shares them (the row's shown builds are a
    /// part of a group).
    private func holds(_ app: AppBuilds, _ installed: InstalledBuild) -> Bool {
        var among = groups[app.bundleID] ?? []
        if !among.contains(where: { Self.overlap($0, app) }) { among.append(app) }
        guard let holder = AppBuilds.holder(of: installed, among: among) else { return false }
        return Self.overlap(holder, app)
    }

    private static func overlap(_ a: AppBuilds, _ b: AppBuilds) -> Bool {
        let ids = Set(a.builds.map(\.id))
        return b.builds.contains { ids.contains($0.id) }
    }

    /// Whether the app here can be opened from Applications (not Applications itself).
    func canOpen(_ app: AppBuilds) -> Bool {
        app.bundleID != Bundle.main.bundleIdentifier && installed[app.bundleID] != nil
    }

    /// Opens the app where it is installed: nil when it has opened, else why not.
    func open(_ app: AppBuilds) async -> String? {
        guard let location = InstalledApps.current(bundleID: app.bundleID, name: app.name) else { return "\(app.name) is not installed." }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: location, configuration: NSWorkspace.OpenConfiguration())
            return nil
        } catch {
            return "\(app.name) did not open: \(error.localizedDescription)"
        }
    }

    /// Every bundle id the catalog has, by its app's name.
    private var idsByName: [String: Set<String>] = [:]

    /// The app's other bundle ids in the catalog, under its name: its
    /// builds from before one bundle id an app (`<id>.Mac`, say), whose copy
    /// an install replaces.
    private func earlierIDs(of build: Build) -> Set<String> {
        (idsByName[build.name] ?? []).subtracting([build.bundleID])
    }

    func refresh(_ apps: [AppBuilds]) {
        groups = Dictionary(grouping: apps, by: \.bundleID)
        idsByName = apps.reduce(into: [:]) { $0[$1.name, default: []].insert($1.bundleID) }
        var found: [String: InstalledBuild] = [:]
        for app in apps { found[app.bundleID] = InstalledApps.installed(bundleID: app.bundleID, name: app.name) }
        installed = found
    }

    /// The build installed of the app's bundle id, when it is one of these
    /// builds: one a bundle id, its Alpha's, say, not its Production's.
    private func held(_ app: AppBuilds) -> InstalledBuild? {
        guard let build = installed[app.bundleID], holds(app, build) else { return nil }
        return build
    }

    func standing(_ app: AppBuilds) -> InstallStanding { app.standing(held(app)) }

    func installedBuild(_ app: AppBuilds) -> Build? { app.build(installed: held(app)) }

    /// The app's state in the apps list, by its bundle id: the build in
    /// /Applications, whichever variant's (never Unknown: the bundle says
    /// which build it is).
    func listedState(_ app: AppBuilds) -> ListedState {
        app.listedState(here: installed[app.bundleID] != nil, installed: installed[app.bundleID])
    }

    /// The build in /Applications, of any variant.
    func listedInstalled(_ app: AppBuilds) -> InstalledBuild? { installed[app.bundleID] }

    func isBusy(_ app: AppBuilds) -> Bool { app.builds.contains { installing.contains($0.id) } }

    /// Where a build downloads from, through the server at `address`: what
    /// an app that updates itself is handed (ApplicationUpdates).
    nonisolated static func installURL(of build: Build, at address: String) -> URL? {
        URL(string: "\(address)/builds/\(build.id)/\(build.downloadKey)/app.zip")
    }

    /// Downloads a build and puts it in place: nil when it is installed,
    /// else why not.
    func install(_ build: Build, client: ServerClient, address: String) async -> String? {
        installing.insert(build.id)
        defer { installing.remove(build.id) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("applications-" + build.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let zip = folder.appendingPathComponent("app.zip")
            try await client.download("/builds/\(build.id)/\(build.downloadKey)/app.zip", at: address, to: zip)
            try await MacInstall.install(zip: zip, build: build, earlier: earlierIDs(of: build))
        } catch {
            return error.localizedDescription
        }
        installed[build.bundleID] = InstalledApps.installed(bundleID: build.bundleID, name: build.name)
        return nil
    }
}
