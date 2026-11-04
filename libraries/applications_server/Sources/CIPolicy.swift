import ApplicationsProtocol
import Foundation

/// What a CI job may publish, by what its verified token says (CIClaims),
/// and as what:
///
/// | The token | The build |
/// | --- | --- |
/// | a repository not configured here | refused |
/// | a bundle id not its repository's (another's, or none's) | refused |
/// | a release branch's push (`refs/heads/release-MAJOR-MINOR`, cut from a commit of main) by a releaser | production; its build's `BuildVariant` must be Production, of that MAJOR.MINOR (`checkVariant`) |
/// | a release branch's push by someone else, or from another event | refused, not made a beta |
/// | a `v*` tag, released (`release`) or pushed (`push`) by a releaser (before release branches) | production; refused for a beta's bundle id (`<id>.Beta`) |
/// | any other tag, or a `v*` tag from another event or someone else | refused, not made a beta |
/// | anything else: a branch, a pull request, main | a beta (an Alpha), whatever its bundle id; a Production `BuildVariant` refused |
///
/// A release branch or a tag is a release's or nothing: its build is a
/// production build (`--config=prod`), and one a releaser did not push is
/// refused, so its job fails where it can be seen, rather than published
/// under the production bundle id as a beta that nobody approved.
///
/// The version a build takes is asked for before it is built, of an app
/// rather than a bundle id: a configured repository's job may ask for any
/// of its bundle ids' apps (`checkVersioning`), whatever its ref.
public struct CIPolicy: Sendable, Equatable {
    /// Each repository (owner/name) and the production bundle ids it
    /// publishes: their betas' (`<id>.Beta`) go with them.
    public var repositories: [String: [String]]
    /// The GitHub logins whose releases are published as production.
    public var releasers: [String]
    /// Each repository's number at GitHub, by its name in lowercase, once
    /// pinned (ServerConfig.repositoryIDs).
    public var repositoryIDs: [String: String]

    public init(repositories: [String: [String]], releasers: [String], repositoryIDs: [String: String] = [:]) {
        self.repositories = repositories
        self.releasers = releasers
        self.repositoryIDs = repositoryIDs
    }

    /// The build's channel, by its token and its bundle id; refused,
    /// saying why.
    public func channel(for claims: CIClaims, bundleID: String) throws -> ReleaseChannel {
        let (repository, ids) = try configured(claims)
        let production = BundleVariant.productionID(bundleID)
        guard ids.contains(production) else {
            let owner = repositories.first { $0.value.contains(production) }?.key
            throw Refusal("\(bundleID) is " + (owner.map { "\($0)'s" } ?? "no repository's") + ", not \(repository)'s, which publishes "
                          + (ids.isEmpty ? "nothing" : ids.sorted().joined(separator: ", ")) + " and their betas")
        }
        // A release branch's push (release-MAJOR-MINOR, cut from a commit of
        // main): production, pushed by a releaser. Any other branch's, a
        // beta (an Alpha: main's and pull requests').
        if claims.refType == "branch" {
            guard let branch = Self.releaseBranch(claims.ref) else { return .beta }
            guard claims.eventName == "push" else {
                throw Refusal("\(branch)'s build came from a \(claims.eventName) event: a release branch publishes on its push")
            }
            guard releasers.contains(where: { $0.lowercased() == claims.actor.lowercased() }) else {
                throw Refusal("\(branch) was pushed by \(claims.actor), who is not a releaser here (applications-server releaser <login>): "
                              + "its build is not published, as production or as a beta")
            }
            guard !BundleVariant.isBeta(bundleID) else {
                throw Refusal("\(bundleID) is a beta's bundle id, and a release branch publishes the production build, \(production)")
            }
            return .production
        }
        guard claims.refType == "tag" else { return .beta }
        let tag = claims.tag ?? claims.ref
        guard tag.hasPrefix("v") else {
            throw Refusal("\(tag) is a tag, and only a release's (v<version>) publishes from a tag")
        }
        guard ["release", "push"].contains(claims.eventName) else {
            throw Refusal("\(tag)'s build came from a \(claims.eventName) event: a release publishes on its release, or its tag's push")
        }
        guard releasers.contains(where: { $0.lowercased() == claims.actor.lowercased() }) else {
            throw Refusal("\(tag) was released by \(claims.actor), who is not a releaser here (applications-server releaser <login>): "
                          + "its build is not published, as production or as a beta")
        }
        guard !BundleVariant.isBeta(bundleID) else {
            throw Refusal("\(bundleID) is a beta's bundle id, and a release publishes the production build, "
                          + "\(production) (built with --config=prod)")
        }
        return .production
    }

    /// A release branch's name, `release-MAJOR-MINOR` (from
    /// `refs/heads/release-0-10`), or nil for any other ref.
    public static func releaseBranch(_ ref: String) -> String? {
        guard ref.hasPrefix("refs/heads/release-") else { return nil }
        let branch = String(ref.dropFirst("refs/heads/".count))
        return releaseLine(branch) == nil ? nil : branch
    }

    /// `release-0-10`'s MAJOR.MINOR, "0.10"; nil for a name that isn't one.
    public static func releaseLine(_ branch: String) -> String? {
        let parts = branch.dropFirst("release-".count).split(separator: "-", omittingEmptySubsequences: false)
        guard branch.hasPrefix("release-"), parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return parts.joined(separator: ".")
    }

    /// A build's variant (its Info.plist's `BuildVariant`: Alpha, Beta or
    /// Production) against what its publish is: a Production build only as
    /// production, and production only of a Production build of its release
    /// branch's MAJOR.MINOR. A build with no variant (an app not yet
    /// building with one) is let be.
    public static func checkVariant(_ variant: String?, version: String, channel: ReleaseChannel, claims: CIClaims) throws {
        guard let variant else { return }
        // AdHoc: a pull request's branch built by hand (workflow_dispatch),
        // never main's or a release branch's.
        if variant == "AdHoc" {
            let branch = claims.ref.hasPrefix("refs/heads/") ? String(claims.ref.dropFirst("refs/heads/".count)) : nil
            guard claims.eventName == "workflow_dispatch", let branch, branch != "main", releaseBranch(claims.ref) == nil else {
                throw Refusal("an AdHoc build (BuildVariant) is a branch's, built by hand (workflow_dispatch) from a pull request's "
                              + "branch; this is \(claims.ref)'s \(claims.eventName)")
            }
            return
        }
        if variant == "Production", channel != .production {
            throw Refusal("a Production build (BuildVariant) is published only from a release-MAJOR-MINOR branch; this is \(claims.ref)'s")
        }
        guard channel == .production, claims.refType == "branch", let branch = releaseBranch(claims.ref) else { return }
        guard variant == "Production" else {
            throw Refusal("\(branch) publishes Production builds (--config=prod); this one's BuildVariant is \(variant)")
        }
        if let line = releaseLine(branch), !version.hasPrefix(line + ".") {
            throw Refusal("\(branch) releases \(line).BUILD; this build is \(version)")
        }
    }

    /// Whether a CI job may ask for an app's next version (`POST
    /// /api/next-version`): its repository is configured here, and the app
    /// is one of its bundle ids' apps. `apps`: the apps each production
    /// bundle id's builds are counted under here, its beta's included (by
    /// apps.json, and by the builds kept). Refused, saying why, if not.
    public func checkVersioning(_ app: String, for claims: CIClaims, apps: [String: Set<String>]) throws {
        let (repository, ids) = try configured(claims)
        let theirs = ids.reduce(into: Set<String>()) { $0.formUnion(apps[$1] ?? []) }
        guard !theirs.contains(app) else { return }
        throw Refusal("\(app) is not \(repository)'s: its bundle ids (" + ids.sorted().joined(separator: ", ")
                      + " and their betas) are " + (theirs.isEmpty ? "no app's yet" : theirs.sorted().joined(separator: " and ") + "'s")
                      + " here, by their builds or applications-server app <bundle id> <app>")
    }

    /// The token's repository as configured here, and the production bundle
    /// ids it publishes; refused when it is not configured, or when its name
    /// is now another repository's than the one pinned.
    func configured(_ claims: CIClaims) throws -> (String, [String]) {
        guard let found = Self.find(claims.repository, in: repositories) else {
            throw Refusal("\(claims.repository) publishes nothing here: on the server's Mac, applications-server repo "
                          + "\(claims.repository) <bundle id>…")
        }
        if let pinned = repositoryIDs[found.0.lowercased()], pinned != claims.repositoryID {
            throw Refusal("\(claims.repository) is repository \(claims.repositoryID) at GitHub, not \(pinned), the one whose builds "
                          + "this server publishes under that name: if the repository was made again, applications-server repo "
                          + "\(found.0) <bundle id>… on the server's Mac lets go of the old one")
        }
        return found
    }

    /// The token's repository's number, to pin: its configured name and
    /// its `repository_id`, when that name has none pinned yet.
    func unpinned(_ claims: CIClaims) -> (String, String)? {
        guard let (name, _) = Self.find(claims.repository, in: repositories), repositoryIDs[name.lowercased()] == nil,
              !claims.repositoryID.isEmpty else { return nil }
        return (name.lowercased(), claims.repositoryID)
    }

    /// A repository's entry, by its name in any case (GitHub's are not
    /// told apart by case).
    static func find(_ repository: String, in repositories: [String: [String]]) -> (String, [String])? {
        repositories.first { $0.key.lowercased() == repository.lowercased() }.map { ($0.key, $0.value) }
    }

    /// Why a CI job's build is not published.
    public struct Refusal: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }
}
