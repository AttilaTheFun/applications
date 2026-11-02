import ApplicationUpdates
import ApplicationsProtocol
import Foundation
import Observation
import PipelineClient
import UIKit

/// Installing on an iPhone or an iPad: a build is handed to iOS by its
/// install link. What is installed is one build a bundle id (an app's
/// Alpha, Beta, AdHoc and Production share it, so the last installed is the
/// one there): whether it is there, iOS says by the app's own link scheme
/// (`visor://`: Applications' Info.plist lists each app's, as iOS answers
/// canOpenURL for those alone), and which build it is, the app says, writing
/// its version and variant to the database it shares with Applications at
/// each launch (ApplicationUpdates). An app that opens but has not said is
/// installed at an unknown version; one that doesn't open is not installed,
/// whatever it said before. An app with no scheme Applications lists is
/// taken at its word, which it may have outlived.
@MainActor
@Observable
final class DeviceInstalls {
    static let platform = "ios"
    /// The apps list's icons, on a phone.
    static let iconSize: CGFloat = 52
    /// A sheet's least size: none on a phone (a sheet there is the screen's
    /// width, and one asked to be wider ran off it), a window's on a Mac.
    static let sheetMinimumWidth: CGFloat? = nil
    static let sheetMinimumHeight: CGFloat? = nil
    /// What this device is, in the apps list's words.
    static var deviceName: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    /// What follows a build handed over.
    static let handedOverWords = "iOS asks to install it; it downloads on the Home Screen."
    /// Installing over the air needs iOS to trust the server's authority.
    static let needsTrustedAuthority = true

    /// The builds handed to iOS that it has not yet said are installed,
    /// by bundle id, with when.
    private(set) var arriving: [String: Date] = [:]
    /// Bumped when what is installed may have changed, for the views.
    private(set) var generation = 0
    private var watching: Task<Void, Never>?
    /// What the apps said of themselves in the shared database, by bundle
    /// id: read again with each refresh.
    private(set) var said: [String: AppRecord] = [:]
    private let updates: AppGroupStore? = try? AppGroupStore.appGroup()

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

    func refresh(_ apps: [AppBuilds]) {
        groups = Dictionary(grouping: apps, by: \.bundleID)
        generation += 1
        guard let updates else { return }
        Task {
            guard let records = try? await updates.records() else { return }
            said = Dictionary(records.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
            generation += 1
        }
    }

    /// The link schemes iOS answers for: the apps' own, as Applications'
    /// Info.plist lists them.
    private static let queried = Set(Bundle.main.infoDictionary?["LSApplicationQueriesSchemes"] as? [String] ?? [])

    /// An app's own link scheme, if iOS can be asked about it: one its
    /// builds declare (not a build's own, `applications-<release>-build-<n>`
    /// or `releases-build-<n>`) that Applications lists.
    static func scheme(_ app: AppBuilds, queried: Set<String> = queried) -> String? {
        app.builds.lazy.flatMap { $0.urlSchemes ?? [] }
            .first { BuildSchemes.parse($0) == nil && !$0.hasPrefix("releases-build-") && queried.contains($0) }
    }

    /// Whether the app is here, by its scheme; nil for one iOS can't be
    /// asked about.
    private func opens(_ app: AppBuilds) -> Bool? {
        guard let scheme = Self.scheme(app), let url = URL(string: scheme + "://") else { return nil }
        return UIApplication.shared.canOpenURL(url)
    }

    /// The build the app said it is, whichever of its builds that is.
    private func saidInstalled(_ app: AppBuilds) -> InstalledBuild? {
        guard let record = said[app.bundleID], let version = record.installedVersion else { return nil }
        return InstalledBuild(bundleID: app.bundleID, version: version, buildNumber: record.installedBuild ?? "",
                              variant: record.installedVariant)
    }

    private var mine: InstalledBuild {
        let info = Bundle.main.infoDictionary ?? [:]
        return InstalledBuild(bundleID: Bundle.main.bundleIdentifier ?? "",
                              version: info["CFBundleShortVersionString"] as? String ?? "",
                              buildNumber: info["CFBundleVersion"] as? String ?? "",
                              executableUUID: Bundle.main.executableURL.flatMap(MachOUUID.uuid(ofFileAt:)) ?? "",
                              variant: info["BuildVariant"] as? String)
    }

    /// The build installed of the app's bundle id, when it is one of these
    /// builds (its Alpha's, say, not its Production's): one a bundle id.
    private func installed(_ app: AppBuilds) -> InstalledBuild? {
        if app.bundleID == Bundle.main.bundleIdentifier { return holds(app, mine) ? mine : nil }
        if opens(app) == false { return nil }
        guard let said = saidInstalled(app), holds(app, said) else { return nil }
        return said
    }

    func standing(_ app: AppBuilds) -> InstallStanding {
        _ = generation
        if let installed = installed(app) { return app.standing(installed) }
        // Here, but it hasn't said which build: none of these is claimed.
        if app.bundleID != Bundle.main.bundleIdentifier, opens(app) == true, saidInstalled(app) == nil { return .installedUnknownVersion }
        return .unknown
    }

    /// The app's state in the apps list, by its bundle id: here (its scheme
    /// opens) and which build it said, whichever variant's (Applications
    /// itself: its own build).
    func listedState(_ app: AppBuilds) -> ListedState {
        _ = generation
        if app.bundleID == Bundle.main.bundleIdentifier { return app.listedState(here: true, installed: mine) }
        return app.listedState(here: opens(app), installed: saidInstalled(app))
    }

    /// The build the app here said it is, of any variant: what the list's
    /// Update row says you have.
    func listedInstalled(_ app: AppBuilds) -> InstalledBuild? {
        _ = generation
        if app.bundleID == Bundle.main.bundleIdentifier { return mine }
        return opens(app) == false ? nil : saidInstalled(app)
    }

    func installedBuild(_ app: AppBuilds) -> Build? {
        _ = generation
        return app.build(installed: installed(app))
    }

    /// Whether the app here can be opened from Applications: by its own
    /// scheme (not Applications itself).
    func canOpen(_ app: AppBuilds) -> Bool {
        _ = generation
        return app.bundleID != Bundle.main.bundleIdentifier && opens(app) == true
    }

    /// Opens the app here, by its scheme: nil when iOS has, else why not.
    func open(_ app: AppBuilds) async -> String? {
        guard let scheme = Self.scheme(app), let url = URL(string: scheme + "://") else {
            return "\(app.name) can't be opened from Applications."
        }
        return await UIApplication.shared.open(url) ? nil : "iOS did not open \(app.name)."
    }

    /// A build handed to iOS still on its way: until iOS says the newest is
    /// installed, for a few minutes at most (the user may have said no).
    func isBusy(_ app: AppBuilds) -> Bool {
        guard let since = arriving[app.bundleID], Date().timeIntervalSince(since) < 180 else { return false }
        return standing(app) != .upToDate
    }

    /// A build's over-the-air install link, through the server at `address`.
    nonisolated static func installURL(of build: Build, at address: String) -> URL? {
        URL(string: InstallLink.make(manifestURL: "\(address)/builds/\(build.id)/\(build.downloadKey)/manifest.plist"))
    }

    /// Hands a build to iOS: nil when it has been, else why not.
    func install(_ build: Build, client: ServerClient, address: String) async -> String? {
        if client.pinning.systemTrusts == false {
            return "Installing needs this device to trust the server's certificate: install its profile from the server's page."
        }
        guard let link = Self.installURL(of: build, at: address) else { return "That build has no install link." }
        guard await UIApplication.shared.open(link) else { return "iOS did not take the install link." }
        arriving[build.bundleID] = Date()
        watch()
        return nil
    }

    /// While builds are on their way, what is installed is looked at again
    /// every two seconds, to see them arrive.
    private func watch() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.generation += 1
                self.arriving = self.arriving.filter { Date().timeIntervalSince($0.value) < 180 }
                if self.arriving.isEmpty { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            self?.watching = nil
        }
    }
}
