import ApplicationsProtocol
import Foundation
import PipelineClient
import PipelineHTTP
import PipelineServer

/// Publishing from CI, which holds no signing key and no password: a
/// GitHub Actions job sends its builds, unsigned, with its OIDC token
/// (docs/CI.md), and the server checks the token (GitHubOIDC), decides
/// what the job may publish and as what (CIPolicy), signs the build
/// (Signer) and publishes it. Before it builds, the job asks for its
/// build's version with the same token (tools/ci/next_version.sh).
///
///     POST /api/publish    Authorization: Bearer <the job's OIDC token>, over HTTPS
///                          the package as the body; X-Applications-Notes and X-Applications-App (base64) and
///                          X-Applications-Commit (a beta's: a pull request's head) as a hand publish has them; the
///                          token's repository, ref, event and actor decide the rest (X-Applications-Release is not
///                          read). 201 with the build; 401 when the token is refused; 403 when the token may not
///                          publish the build; 400 when the package is.
///     POST /api/next-version
///                          Authorization: Bearer <the job's OIDC token>, over HTTPS
///                          {"app": "<app>", "line": "MAJOR.MINOR"}: the version the token's commit (its `sha`)
///                          takes, {"version": "MAJOR.MINOR.BUILD"}, as `applications-server next-version <app>
///                          <line> --commit <sha>` gives it (asked again, the same). 401 when the token is refused;
///                          403 when its repository is not configured here or the app is not one of its bundle
///                          ids' apps; 400 when the request is not one.
extension ApplicationsServer {
    /// A request's bearer value, if it has one.
    static func bearer(_ request: HTTPRequest) -> String? {
        guard let header = request.headers["authorization"], header.lowercased().hasPrefix("bearer ") else { return nil }
        return String(header.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
    }

    /// The settings as config.json has them now: what CI may publish is
    /// read at each of its publishes, so `repo`, `releaser`, `oidc` and
    /// `notary` need no restart.
    var currentSettings: ServerConfig { ServerConfig.load(paths.config) ?? config }

    /// A CI job's publish: its token checked, then its build.
    func publishFromCI(_ request: HTTPRequest, token: String) async -> HTTPResponse {
        let settings = currentSettings
        let claims: CIClaims
        do {
            claims = try await oidc.verify(token, audience: settings.oidcAudience)
        } catch {
            return .error("The token was refused: \(error)", status: 401)
        }
        guard let file = request.bodyFile else { return .error("Post the .ipa, .zip, .dmg or .apk as the body", status: 400) }
        let notes = request.headers["x-applications-notes"].flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let app = request.headers["x-applications-app"].flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
        let commit = request.headers["x-applications-commit"].flatMap { $0.count >= 7 && $0.allSatisfy(\.isHexDigit) ? $0 : nil }
        do {
            let build = try await publish(ci: file, claims: claims, settings: settings, notes: notes, app: app, commit: commit)
            return .json(listed(build), status: 201)
        } catch let refusal as CIPolicy.Refusal {
            return .error("Refused: \(refusal)", status: 403)
        } catch let refusal as PackageCheck.Refusal {
            return .error("Refused: \(refusal)", status: 400)
        } catch {
            return .error("Not an .ipa, a Mac app or an .apk this server reads: \(error)", status: 400)
        }
    }

    /// A CI job's next version: its token checked, then the app it asks
    /// for, which must be one of its repository's (CIPolicy), then the
    /// version of the token's commit, kept as that commit's.
    func nextVersionFromCI(_ request: HTTPRequest, token: String) async -> HTTPResponse {
        let settings = currentSettings
        let claims: CIClaims
        do {
            claims = try await oidc.verify(token, audience: settings.oidcAudience)
        } catch {
            return .error("The token was refused: \(error)", status: 401)
        }
        guard let asked = Self.versionRequest(request) else { return .error("An app and a line (MAJOR.MINOR) are needed", status: 400) }
        do {
            try CIPolicy(repositories: settings.repositories, releasers: settings.releasers)
                .checkVersioning(asked.app, for: claims, apps: appsByBundleID())
        } catch {
            return .error("Refused: \(error)", status: 403)
        }
        let version = nextVersion(app: asked.app, line: asked.line, commit: claims.sha)
        FileManager.default.standardError("applications-server: \(claims.repository)'s run \(claims.runID) (\(claims.workflowRef), "
                                          + "\(claims.eventName) by \(claims.actor)) numbered \(asked.app) \(version) for \(claims.sha)")
        return .json(NextVersionAnswer(version: version))
    }

    /// A NextVersionRequest, if the body is one: an app, and a line that is
    /// MAJOR.MINOR.
    static func versionRequest(_ request: HTTPRequest) -> NextVersionRequest? {
        guard let asked = try? WireCoding.decoder().decode(NextVersionRequest.self, from: request.body),
              !asked.app.isEmpty, asked.isLine else { return nil }
        return asked
    }

    /// The apps each production bundle id's builds are counted under here,
    /// its beta's (`<id>.Beta`) included: as apps.json names either id, and
    /// as each build kept is counted (Build.identity).
    func appsByBundleID() -> [String: Set<String>] {
        let names = appNames.all()
        var apps: [String: Set<String>] = [:]
        for (bundleID, app) in names { apps[BundleVariant.productionID(bundleID), default: []].insert(app) }
        for build in builds.all() { apps[build.productionBundleID, default: []].insert(build.identity(names)) }
        return apps
    }

    /// A build a CI job sent, published as its verified claims allow
    /// (CIPolicy): signed here, by the server's identities and profiles, a
    /// beta's with the development identity and production's with the
    /// production one (and its scheme on an iPhone), a Mac app's with
    /// Developer ID and notarized; then kept, and the devices told. The
    /// reading and signing (minutes, notarizing) run off the server's actor,
    /// which answers the devices meanwhile.
    public func publish(ci package: URL, claims: CIClaims, settings: ServerConfig? = nil, notes: String, app: String? = nil,
                        commit: String? = nil) async throws -> Build {
        let settings = settings ?? currentSettings
        let policy = CIPolicy(repositories: settings.repositories, releasers: settings.releasers)
        let signer = signer(settings)
        let builds = builds
        let readied = try await Self.offActor { () throws -> Readied in
            let (file, metadata) = try builds.unpack(package)
            let channel = try policy.channel(for: claims, bundleID: metadata.bundleID)
            try CIPolicy.checkVariant(metadata.buildVariant, version: metadata.version, channel: channel, claims: claims)
            let origin = Self.origin(of: claims, channel: channel, commit: commit)
            let buildScheme = try builds.ready(file, metadata: metadata, channel: channel, commit: origin.commit, signer: signer)
            return Readied(file: file, metadata: metadata, channel: channel, origin: origin, buildScheme: buildScheme)
        }
        let marked = AppNames.marker(in: notes)
        let channels = channels.snapshot(names: appNames.all())
        let build = try builds.keep(readied.file, metadata: readied.metadata, buildScheme: readied.buildScheme, notes: marked.notes,
                                    app: app ?? marked.app, origin: readied.origin, channel: readied.channel) {
            channels.channel(of: $0) == .production
        }
        FileManager.default.standardError("applications-server: \(claims.repository)'s run \(claims.runID) (\(claims.workflowRef), "
                                          + "\(claims.eventName) by \(claims.actor)) published \(build.bundleID) \(build.versionTitle), "
                                          + readied.channel.title.lowercased())
        await announce(build)
        return build
    }

    /// A package read, decided on, signed and checked, to keep.
    struct Readied: Sendable {
        var file: URL
        var metadata: IPAMetadata
        var channel: ReleaseChannel
        var origin: BuildOrigin
        var buildScheme: String?
    }

    /// Where a CI build came from: a release's, the tag's commit, as its
    /// token says; a beta's, the commit the job says it built (a pull
    /// request's head, which the token does not name) or else the token's,
    /// and the token's branch and pull request.
    static func origin(of claims: CIClaims, channel: ReleaseChannel, commit: String?) -> BuildOrigin {
        guard channel == .beta else { return BuildOrigin(commit: claims.sha) }
        return BuildOrigin(commit: commit ?? claims.sha, branch: claims.branch, pullRequest: claims.pullRequest)
    }

    /// The signer of CI's builds, with this Mac's identities, the profiles
    /// here, and notarytool with the notary key if there is one.
    func signer(_ settings: ServerConfig) -> Signer {
        Signer(tools: codeSigning, notary: notary ?? notaryTool(settings), profiles: paths.profiles, team: settings.apnsTeamID)
    }

    func notaryTool(_ settings: ServerConfig) -> any Notarizing {
        guard !settings.notaryKeyID.isEmpty, !settings.notaryIssuer.isEmpty, FileManager.default.fileExists(atPath: paths.notaryKey.path) else {
            return SkippedNotary(reason: "no notary key here (applications-server notary)")
        }
        return NotaryTool(key: paths.notaryKey, keyID: settings.notaryKeyID, issuer: settings.notaryIssuer)
    }

    /// Work that takes long (codesign, notarytool), on a queue of its own
    /// rather than the server's actor or Swift's few threads.
    static func offActor<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// The code CI publishes with (`applications-server code --ci`).
    public func ciCode() throws -> CICode { CICode(addresses: addresses, ca: try authority.fingerprint()) }

    /// What `status` says of CI and signing: the repositories, the
    /// releasers, the notary key's id, the kinds of identity here and the
    /// profiles' bundle ids and kinds. Never a team, a certificate's name,
    /// a device or a key.
    func ciStatus() -> [String] {
        let repositories = config.repositories.keys.sorted().map { "\($0) (\(config.repositories[$0]?.joined(separator: ", ") ?? ""))" }
        let hasNotaryKey = !config.notaryKeyID.isEmpty && FileManager.default.fileExists(atPath: paths.notaryKey.path)
        let identities = (try? codeSigning.identities()) ?? []
        let kinds = SigningIdentity.Kind.allCases.filter { kind in identities.contains { $0.kind == kind } }.map(\.rawValue)
        let profiles = ProfileFolder(folder: paths.profiles, tools: codeSigning).all()
        var byBundle: [String: [String]] = [:]
        for profile in profiles {
            byBundle[profile.bundleID, default: []].append(profile.kind.rawValue + (profile.expires > Date() ? "" : ", expired"))
        }
        return [
            "CI: " + (repositories.isEmpty ? "no repository publishes with its token (applications-server repo <owner/repo> <bundle id>…)"
                : repositories.joined(separator: "; ") + ", and their betas") + "; tokens for the audience \(config.oidcAudience)",
            "Releasers: " + (config.releasers.isEmpty ? "none, so CI publishes no release (applications-server releaser <login>)"
                : config.releasers.joined(separator: ", ")),
            "Notary: " + (hasNotaryKey ? "App Store Connect key \(config.notaryKeyID)"
                : "no key (applications-server notary): Mac apps are signed, not notarized"),
            "Signing identities: " + (kinds.isEmpty ? "none in this Mac's keychain" : kinds.joined(separator: ", ")),
            "Profiles: " + (byBundle.isEmpty ? "none in \(paths.profiles.path)"
                : byBundle.keys.sorted().map { "\($0) (\(byBundle[$0]?.joined(separator: "; ") ?? ""))" }.joined(separator: ", ")),
        ]
    }
}

/// What CI is told of the server (`applications-server code --ci`, kept as
/// a repository's secret): its addresses and the fingerprint of its
/// certificate authority, which tools/ci/publish_from_ci.sh holds the
/// authority the server presents to. No password: a job's token is its
/// permission. base64url of its JSON, which has no escaped slashes, so a
/// shell reads it with sed.
public struct CICode: Codable, Sendable, Equatable {
    public var v = 1
    public var addresses: [String]
    /// SHA-256 of the authority's certificate (DER), lowercase hex.
    public var ca: String

    public init(addresses: [String], ca: String) {
        self.addresses = addresses
        self.ca = ca
    }

    public var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(parsing text: String) {
        guard let data = GitHubOIDC.base64URL(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let code = try? JSONDecoder().decode(Self.self, from: data), !code.addresses.isEmpty, code.ca.count == 64 else { return nil }
        self = code
    }
}
