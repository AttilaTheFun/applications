import ApplicationsProtocol
import Foundation
import PipelineClient
import PipelineHTTP

/// Releases: each app across its platforms, its beta (`<id>.Beta`) and
/// its production builds under one name, each build on its channel (beta,
/// or production when a release published it), and its pull requests'
/// builds apart.
///
///     GET  /api/catalog                         every app and its builds
///     GET  /api/builds?commit=<sha>             a commit's builds, the newest first
///     GET  /api/build-number?commit=<sha>       the commit's build numbers
extension ApplicationsServer {
    /// Every app, the one with the newest build first.
    public func catalog() -> [AppRelease] {
        let all = builds.all()
        let names = appNames.all()
        let channels = channels.snapshot(names: names)
        var builtByApp: [String: [Build]] = [:]
        for build in all {
            var listed = listed(build, channels: channels)
            // What the app sees is the app the server counts it under.
            listed.app = build.identity(names)
            builtByApp[listed.app ?? build.name, default: []].append(listed)
        }
        var apps: [AppRelease] = []
        for (app, built) in builtByApp {
            // Main's builds and releases' are the app's; a branch's are its
            // pull request's.
            let main = built.filter { $0.origin?.pullRequest == nil }
            var byPullRequest: [Int: [Build]] = [:]
            for build in built { if let number = build.origin?.pullRequest { byPullRequest[number, default: []].append(build) } }
            let pullRequests = byPullRequest.map { number, builds in
                PullRequestRelease(number: number, branch: builds.first?.origin?.branch, builds: builds)
            }.sorted { $0.number > $1.number }
            // Production's icon stands for the app before a beta's.
            let icon = main.first { $0.hasIcon && $0.channel == .production } ?? main.first(where: \.hasIcon) ?? built.first(where: \.hasIcon)
            apps.append(AppRelease(app: app, iconBuild: icon?.id, builds: main, pullRequests: pullRequests))
        }
        let newest = Dictionary(uniqueKeysWithValues: apps.map { app in
            (app.app, builtByApp[app.app]?.map(\.published).max() ?? .distantPast)
        })
        return apps.sorted { (newest[$0.app] ?? .distantPast, $1.app) > (newest[$1.app] ?? .distantPast, $0.app) }
    }

    /// The build number the next build of an app's version takes: one past
    /// the highest of any build of it here (a pull request's too) or given
    /// to a commit, 1 for the first. CI stamps it into each build before
    /// building, so every build published is one more (pushes build on
    /// their own now). With a commit, the number is kept as that commit's,
    /// and the same number is its answer if asked again.
    public func nextBuildNumber(app: String, version: String, commit: String? = nil) -> Int {
        if let commit, let given = buildNumbers.of(commit: commit).first(where: { $0.app == app && $0.version == version }) {
            return given.build
        }
        let names = appNames.all()
        let built = builds.nextBuildNumber(version: version) { $0.identity(names) == app }
        let given = (buildNumbers.all().filter { $0.app == app && $0.version == version }.map(\.build).max() ?? 0) + 1
        let number = max(built, given)
        if let commit { buildNumbers.keep(BuildNumber(app: app, version: version, build: number, commit: commit)) }
        return number
    }

    /// The version the next build of an app's line takes, from 0.38: the
    /// line is MAJOR.MINOR, and each build is a version of its own,
    /// MAJOR.MINOR.BUILD, with build number 1. BUILD is one past the
    /// highest of the line's builds here (a pull request's too) or given to
    /// a commit, 1 for the first. With a commit, the version is kept as
    /// that commit's, and the same version is its answer if asked again.
    public func nextVersion(app: String, line: String, commit: String? = nil) -> String {
        let prefix = line + "."
        func build(of version: String) -> Int? {
            guard version.hasPrefix(prefix) else { return nil }
            return Int(version.dropFirst(prefix.count))
        }
        if let commit, let given = buildNumbers.of(commit: commit).first(where: { $0.app == app && build(of: $0.version) != nil }) {
            return given.version
        }
        let names = appNames.all()
        let built = builds.all().filter { $0.identity(names) == app }.compactMap { build(of: $0.version) }.max() ?? 0
        let given = buildNumbers.all().filter { $0.app == app }.compactMap { build(of: $0.version) }.max() ?? 0
        let version = "\(line).\(max(built, given) + 1)"
        if let commit { buildNumbers.keep(BuildNumber(app: app, version: version, build: 1, commit: commit)) }
        return version
    }

    /// A commit's builds (its sha or the start of it), the newest first.
    public func builds(ofCommit commit: String) -> [Build] {
        let channels = channels.snapshot(names: appNames.all())
        return builds.all().filter { build in
            guard let made = build.origin?.commit else { return false }
            return made.hasPrefix(commit) || commit.hasPrefix(made)
        }.sorted { $0.published > $1.published }.map { listed($0, channels: channels) }
    }

    /// A commit's build numbers: those CI gave it, and those of its builds
    /// here (a build published without a number given first).
    public func buildNumbers(commit: String) -> [BuildNumber] {
        var numbers = Set(buildNumbers.of(commit: commit))
        let names = appNames.all()
        for build in builds.all() {
            guard let made = build.origin?.commit, made.hasPrefix(commit) || commit.hasPrefix(made), let number = Int(build.buildNumber) else { continue }
            numbers.insert(BuildNumber(app: build.identity(names), version: build.version, build: number, commit: made))
        }
        return numbers.sorted { ($0.app, $0.build) < ($1.app, $1.build) }
    }

    /// The catalog as the apps read it: with each app's main builds by
    /// version too (`versions`, newest first), which Applications from
    /// before builds had channels of their own reads instead of `builds`,
    /// on the channels it knows ("alpha" for beta), and which it needs to
    /// read the catalog to update itself.
    func catalogAnswer() -> HTTPResponse {
        let catalog = catalog()
        guard let data = try? WireCoding.encoder().encode(catalog),
              var apps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], apps.count == catalog.count else {
            return .json(catalog)
        }
        for (index, app) in catalog.enumerated() {
            let builds = apps[index]["builds"] as? [[String: Any]] ?? []
            guard builds.count == app.builds.count else { continue }
            var byVersion: [String: [[String: Any]]] = [:]
            for (build, encoded) in zip(app.builds, builds) { byVersion[build.version, default: []].append(encoded) }
            apps[index]["versions"] = byVersion.keys.sorted(by: Self.newer).map { version in
                let production = app.builds.contains { $0.version == version && $0.channel == .production }
                return ["version": version, "channel": production ? "production" : "alpha", "builds": byVersion[version] ?? []] as [String: Any]
            }
        }
        guard let patched = try? JSONSerialization.data(withJSONObject: apps, options: [.sortedKeys]) else { return .json(catalog) }
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: .data(patched))
    }

    /// "0.35" before "0.34", by their numbers.
    static func newer(_ a: String, _ b: String) -> Bool {
        func numbers(_ text: String) -> [Int] { text.split { !$0.isNumber }.compactMap { Int($0) } }
        return numbers(b).lexicographicallyPrecedes(numbers(a))
    }
}
