import ApplicationsProtocol
import CryptoKit
import Foundation
import PipelineClient
import PipelineHTTP
import PipelineServer

/// The server: its settings, builds and devices, and what each request
/// is answered with. The listeners hand requests here; publishing a build
/// tells the devices.
public actor ApplicationsServer {
    public static let version = "0.10.0"
    /// The notification category of a new build, whose action installs it.
    public static let buildCategory = "BUILD"
    /// Where an upload goes, read to a file rather than memory.
    public static let publishPath = "/api/publish"

    let paths: ServerPaths
    public private(set) var config: ServerConfig
    let builds: BuildStore
    let devices: DeviceStore
    let authority: CertificateAuthority
    /// The channels of builds from before builds had their own (ChannelStore).
    let channels: ChannelStore
    let buildNumbers: BuildNumberStore
    let appNames: AppNames
    /// What signs builds here: this Mac's keychain and codesign
    /// (SystemCodeSigning), or a test's fake.
    let codeSigning: any CodeSigning
    /// What notarizes CI's Mac apps: nil for notarytool with the key kept
    /// here (`applications-server notary`), read at each publish; a test's
    /// fake.
    let notary: (any Notarizing)?
    /// CI's tokens, checked against GitHub's keys.
    let oidc: GitHubOIDC
    /// The addresses the HTTPS port is reached at (https://ip:port).
    public private(set) var addresses: [String] = []

    public init(paths: ServerPaths, name: String, codeSigning: any CodeSigning = SystemCodeSigning(), notary: (any Notarizing)? = nil,
                oidc: GitHubOIDC = GitHubOIDC()) throws {
        try paths.prepare()
        self.paths = paths
        config = try ServerConfig.loadOrCreate(at: paths.config, name: name)
        self.codeSigning = codeSigning
        self.notary = notary
        self.oidc = oidc
        builds = BuildStore(folder: paths.builds)
        devices = DeviceStore(file: paths.devices)
        authority = CertificateAuthority(folder: paths.tls, name: "Applications")
        channels = ChannelStore(file: paths.channels)
        buildNumbers = BuildNumberStore(file: paths.buildNumbers)
        appNames = AppNames(file: paths.appNames)
    }

    /// Readies the certificate for the addresses the computer has now.
    public func prepareTLS(local: [LocalAddress], hostName: String) throws {
        try authority.ensure(names: ServerAddressing.certificateNames(local, hostName: hostName), title: config.name)
        addresses = ServerAddressing.addresses(local, hostName: hostName, port: config.httpsPort)
    }

    public nonisolated func tlsIdentity() throws -> (SecIdentity, SecCertificate) { try authority.identity() }

    public func issuedNames() -> [String] { authority.issuedNames }

    public var hello: Hello { Hello(id: config.id, name: config.name, addresses: addresses, version: Self.version, kind: "applications") }

    /// The code the app is set up with.
    public func connectionCode() throws -> ConnectionCode {
        ConnectionCode(id: config.id, name: config.name, addresses: addresses, password: config.password, ca: try authority.fingerprint())
    }

    /// Keeps the APNs key: the .p8's contents in apns.p8, its ids in the
    /// settings.
    public func setAPNsKey(pem: String, keyID: String, teamID: String) throws {
        _ = try PushSender(pem: pem, keyID: keyID, teamID: teamID)
        try pem.write(to: paths.apnsKey, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.apnsKey.path)
        config.apnsKeyID = keyID
        config.apnsTeamID = teamID
        try config.save(to: paths.config)
    }

    /// Whether the API asks for the password (`applications-server password on|off`).
    public func setRequirePassword(_ required: Bool) throws {
        config.requirePassword = required
        try config.save(to: paths.config)
    }

    /// Watches `repository`'s draft release "inbox" for builds (empty: none).
    public func setInbox(_ repository: String) throws {
        config.inbox = repository
        try config.save(to: paths.config)
    }

    /// The bundle ids a repository's CI publishes, production's (a beta's
    /// given is taken as its production's); none: it publishes nothing.
    public func setRepository(_ repository: String, bundleIDs: [String]) throws {
        config.repositories = config.repositories.filter { $0.key.lowercased() != repository.lowercased() }
        var ids: [String] = []
        for id in bundleIDs.map(BundleVariant.productionID) where !ids.contains(id) { ids.append(id) }
        if !ids.isEmpty { config.repositories[repository] = ids }
        try config.save(to: paths.config)
    }

    /// Whether a GitHub login's releases are published as production.
    public func setReleaser(_ login: String, _ releases: Bool) throws {
        config.releasers.removeAll { $0.lowercased() == login.lowercased() }
        if releases { config.releasers.append(login) }
        try config.save(to: paths.config)
    }

    /// Keeps the App Store Connect API key Mac apps are notarized with: the
    /// .p8's contents in notary.p8, its id and issuer in the settings.
    public func setNotaryKey(pem: String, keyID: String, issuer: String) throws {
        // An App Store Connect API key is a P-256 key, as an APNs key is.
        _ = try P256.Signing.PrivateKey(pemRepresentation: pem)
        try pem.write(to: paths.notaryKey, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.notaryKey.path)
        config.notaryKeyID = keyID
        config.notaryIssuer = issuer
        try config.save(to: paths.config)
    }

    /// The audience CI asks GitHub's tokens for.
    public func setOIDCAudience(_ audience: String) throws {
        config.oidcAudience = audience
        try config.save(to: paths.config)
    }

    var pushSender: PushSender? {
        guard let pem = try? String(contentsOf: paths.apnsKey, encoding: .utf8) else { return nil }
        return try? PushSender(pem: pem, keyID: config.apnsKeyID, teamID: config.apnsTeamID)
    }

    /// Every app's builds pruned by the retention (BuildStore), production
    /// builds kept.
    public func pruneBuilds(now: Date = Date()) {
        let channels = channels.snapshot(names: appNames.all())
        builds.pruneAll(keeps: { channels.channel(of: $0) == .production }, now: now)
    }

    /// A build taken in from a file (published by hand, or from the inbox),
    /// and the devices told of it: always a beta. Production comes only
    /// from a release's CI (`publish(ci:…)`).
    public func publish(package: URL, notes: String, app: String? = nil, origin: BuildOrigin? = nil) async throws -> Build {
        // The app as the publisher named it, or as the notes' marker does
        // (an inbox upload's way); the marker is not part of the notes.
        let marked = AppNames.marker(in: notes)
        let channels = channels.snapshot(names: appNames.all())
        // Production builds stay, however many come after.
        let build = try builds.add(package: package, notes: marked.notes, app: app ?? marked.app, origin: origin) {
            channels.channel(of: $0) == .production
        }
        await announce(build)
        return build
    }

    /// The scheme CI stamps into an app's production build of a commit
    /// before building it (BuildSchemes): given under the current release,
    /// the same when asked again; none for Applications or a beta's bundle
    /// id. Throws `SchemeNumbers.UsedUp` once the release's are given out.
    public func buildScheme(bundleID: String, commit: String) throws -> BuildSchemeAnswer {
        try builds.scheme(bundleID: bundleID, commit: commit)
    }

    /// Tells every device of a build: "A new Visor build is ready to
    /// install", the notes' summary under it, and Install on the
    /// notification (its category, `buildCategory`).
    func announce(_ build: Build) async {
        // The phones' pushes are for the phones' builds; the Mac app asks
        // the server for its own.
        guard build.platform == "ios" else { return }
        let targets = devices.all()
        guard let sender = pushSender, !targets.isEmpty else { return }
        let summary = ReleaseNotes(build.notes).summary
        let detail = summary.isEmpty ? "" : " — " + summary
        let what = build.origin?.pullRequest.map { "A new \(build.name) build of pull request #\($0)" } ?? "A new \(build.name) build"
        let gone = await sender.send(to: targets, title: "\(what) is ready to install",
                                     body: "\(build.name) \(build.versionTitle)\(detail)", category: Self.buildCategory,
                                     data: ["build": build.id])
        for token in gone { devices.forget(token: token) }
    }

    func authorized(_ request: HTTPRequest) -> Bool {
        guard config.requirePassword else { return true }
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        return ConstantTime.equal(String(header.dropFirst("Bearer ".count)), config.password)
    }

    /// What the server has, for `applications-server status`.
    public func status() -> String {
        let apps = builds.apps(platform: "ios")
        var lines = ["\(config.name), Applications Server \(Self.version)", "Addresses: " + addresses.joined(separator: ", "),
                     "Pushes: " + (pushSender == nil ? "no APNs key (applications-server apns)" : "APNs key \(config.apnsKeyID)"),
                     "Devices: \(devices.all().map(\.name).joined(separator: ", "))",
                     "Inbox: " + (config.inbox.isEmpty ? "not watched (applications-server inbox <owner/repo>)" : config.inbox + ", release \"inbox\"")]
        lines += ciStatus()
        let schemes = builds.schemesGiven()
        lines.append("Build schemes: Applications \(schemes.release)'s, \(schemes.given) of \(BuildSchemes.othersLimit) given")
        for app in apps + builds.apps(platform: "macos") { lines.append("\(app.name): \(app.builds.map(\.versionTitle).joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    /// A build as an authenticated listing gives it: with its links' key,
    /// and its channel (`channels`, read once for many builds).
    func listed(_ build: Build, channels: ChannelStore.Snapshot? = nil) -> Build {
        var build = build
        build.downloadKey = DownloadKey.make(password: config.password, build: build.id)
        build.channel = (channels ?? self.channels.snapshot(names: appNames.all())).channel(of: build)
        return build
    }
}
