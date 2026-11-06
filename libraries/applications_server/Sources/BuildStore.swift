import ApplicationsProtocol
import Foundation
import PipelineClient
import PipelineServer

/// The published builds, a folder each under builds/: build.json, the
/// package (app.ipa, a Mac app's app.zip, an Android app's app.apk), its
/// icon. Kept (prune): production builds for good; of the others, each
/// bundle's newest for good, an Alpha (or a build with no variant) for a
/// week and a Beta for two; a pull request's newest, and up to its newest
/// three from the week.
public struct BuildStore: Sendable {
    let folder: URL
    /// How long a build that is not the newest, nor production, is kept:
    /// an Alpha (or one with no variant) a week.
    static let retention: TimeInterval = 7 * 86_400
    /// A Beta (BuildVariant), two weeks.
    static let betaRetention: TimeInterval = 14 * 86_400

    /// How long a build that is not its bundle's newest, nor production, is kept.
    static func retention(of build: Build) -> TimeInterval { build.buildVariant == "Beta" ? betaRetention : retention }

    /// An AdHoc build (a pull request's branch, built by hand) is never its
    /// bundle's newest kept for good: it goes after a week whatever comes.
    static func isAdHoc(_ build: Build) -> Bool { build.buildVariant == "AdHoc" }
    /// A pull request's builds kept, of each app: its newest three (from
    /// the week; its newest whenever it came).
    static let keptPerPullRequest = 3

    public init(folder: URL) {
        self.folder = folder
    }

    /// Every build, newest first.
    public func all() -> [Build] {
        let decoder = WireCoding.decoder()
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { buildFolder in
            guard let data = try? Data(contentsOf: buildFolder.appendingPathComponent("build.json")) else { return nil }
            return try? decoder.decode(Build.self, from: data)
        }.sorted { $0.published > $1.published }
    }

    /// The builds by app, the app with the newest build first; those for
    /// one platform ("ios", "macos", "android"), or all.
    public func apps(platform: String? = nil) -> [AppBuilds] {
        var order: [String] = []
        var grouped: [String: [Build]] = [:]
        for build in all() where platform == nil || build.platform == platform {
            if grouped[build.bundleID] == nil { order.append(build.bundleID) }
            grouped[build.bundleID, default: []].append(build)
        }
        return order.map { AppBuilds(bundleID: $0, name: grouped[$0]?.first?.name ?? $0, builds: grouped[$0] ?? []) }
    }

    public func build(_ id: String) -> Build? {
        guard Self.isID(id), let data = try? Data(contentsOf: buildFolder(id).appendingPathComponent("build.json")) else { return nil }
        return try? WireCoding.decoder().decode(Build.self, from: data)
    }

    /// The build's package: its .ipa, its Mac app's .zip, or its .apk.
    public func package(_ id: String) -> URL? {
        guard Self.isID(id) else { return nil }
        return Self.packageNames.map { buildFolder(id).appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A Mac build's disk image (app.dmg), made when it was promoted to
    /// production, if it has one.
    public func diskImage(_ id: String) -> URL? {
        guard Self.isID(id) else { return nil }
        let dmg = buildFolder(id).appendingPathComponent("app.dmg")
        return FileManager.default.fileExists(atPath: dmg.path) ? dmg : nil
    }

    /// A disk image moved in beside a kept build's package.
    func keepDiskImage(_ file: URL, for id: String) throws {
        let destination = buildFolder(id).appendingPathComponent("app.dmg")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
    }

    public func icon(_ id: String) -> Data? {
        guard Self.isID(id) else { return nil }
        return try? Data(contentsOf: buildFolder(id).appendingPathComponent("icon.png"))
    }

    /// What a build's package is kept as, by platform.
    static let packageNames = ["app.ipa", "app.zip", "app.apk"]
    static func packageName(platform: String) -> String {
        switch platform {
        case "macos": return "app.zip"
        case "android": return "app.apk"
        default: return "app.ipa"
        }
    }

    /// Takes in a package (moved here from `file`): an .ipa, a Mac app's
    /// .zip, a Mac app's disk image (kept as a .zip), or an .apk. Reads it, keeps
    /// it, and lets the app's builds go that are kept no more (prune).
    ///
    /// What it takes in so is a beta, kept as it came, never numbered nor
    /// signed again, whatever its bundle id (a CI that builds commits with
    /// the production id publishes betas of it): a build published by hand
    /// or from the inbox. Production comes only from a release's CI, which
    /// the server signs (`ready` with a Signer, ApplicationsServer+CI).
    public func add(package file: URL, notes: String, app: String? = nil, origin: BuildOrigin? = nil,
                    now: Date = Date(), keeps: (Build) -> Bool = { _ in false }) throws -> Build {
        let (file, metadata) = try unpack(file)
        let buildScheme = try ready(file, metadata: metadata, channel: .beta, commit: origin?.commit)
        return try keep(file, metadata: metadata, buildScheme: buildScheme, notes: notes, app: app, origin: origin, channel: .beta,
                        now: now, keeps: keeps)
    }

    /// A package as it came, read: a Mac app's disk image made the .zip
    /// kept. The first of what `add` does, done apart when the server signs
    /// CI's builds, whose channel waits for what the package is.
    func unpack(_ file: URL) throws -> (URL, IPAMetadata) {
        var file = file
        if !IPAMetadata.isZip(file) {
            let zip = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".zip")
            try IPAMetadata.zip(fromDiskImage: file, to: zip)
            try? FileManager.default.removeItem(at: file)
            file = zip
        }
        return (file, try IPAMetadata.read(file))
    }

    /// A package readied to keep, its build scheme returned: refused as
    /// production when its bundle id is a beta's, or when no signer is
    /// given (production is CI's, which the server signs); an .ipa's
    /// AppleDouble files taken out; signed by the server when `signer` is
    /// given (CI's builds: an iPhone app with the development identity as a
    /// beta and the production one as production, its scheme given, a Mac
    /// app with Developer ID and notarized), else as it came; its signature
    /// checked as the device checks it. Slow when it signs (minutes,
    /// notarizing): the server runs it off its actor.
    func ready(_ file: URL, metadata: IPAMetadata, channel: ReleaseChannel, commit: String?, signer: Signer? = nil) throws -> String? {
        if channel == .production, BundleVariant.isBeta(metadata.bundleID) {
            throw PackageCheck.Refusal("\(metadata.bundleID) is a beta's bundle id, so its build is a beta: a release publishes the "
                                       + "production build, \(BundleVariant.productionID(metadata.bundleID)) (built with --config=prod)")
        }
        if metadata.platform == "ios" { try PackageCheck.strip(ipa: file) }
        guard let signer else {
            guard channel == .beta else { throw PackageCheck.Refusal(Self.productionIsCIs) }
            try PackageCheck.verify(package: file, platform: metadata.platform)
            return nil
        }
        switch metadata.platform {
        case "ios" where channel == .production:
            return try signProduction(file, metadata: metadata, commit: commit, signer: signer)
        case "ios":
            try signer.sign(ipa: file, .development)
        case "macos":
            if case .skipped(let why) = try signer.sign(macZip: file) {
                FileManager.default.standardError("applications-server: \(metadata.bundleID) \(metadata.version) is signed, not notarized: \(why)")
            }
        default:
            // An Android app is published as it came: the server signs none,
            // and one with no signature of v2 or later is refused below.
            break
        }
        try PackageCheck.verify(package: file, platform: metadata.platform)
        return nil
    }

    /// Why a build is not made production by hand.
    public static let productionIsCIs = "a build is production only when a release's CI publishes it, with its OIDC token (a v* tag "
        + "released by a releaser: docs/CI.md); published by hand it is a beta, so publish it without asking for a release"

    /// The last of what `add` does: the readied package moved into the
    /// store, its build kept, and the app's builds that are kept no more let
    /// go.
    func keep(_ file: URL, metadata: IPAMetadata, buildScheme: String?, notes: String, app: String?, origin: BuildOrigin?,
              channel: ReleaseChannel, now: Date = Date(), keeps: (Build) -> Bool) throws -> Build {
        let id = Self.newID(now: now)
        let destination = buildFolder(id)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let package = destination.appendingPathComponent(Self.packageName(platform: metadata.platform))
        try FileManager.default.moveItem(at: file, to: package)
        let size = ((try? FileManager.default.attributesOfItem(atPath: package.path)[.size]) as? NSNumber)?.int64Value ?? 0
        if let icon = metadata.icon { try icon.write(to: destination.appendingPathComponent("icon.png")) }
        // The metadata was read before a scheme was added by signing the app
        // again: the build lists what its app now carries.
        var urlSchemes = metadata.urlSchemes
        if let buildScheme, !urlSchemes.contains(buildScheme) { urlSchemes.append(buildScheme) }
        let build = Build(id: id, bundleID: metadata.bundleID, name: metadata.name, version: metadata.version,
                          buildNumber: metadata.buildNumber, platform: metadata.platform, published: now, size: size, notes: notes,
                          hasIcon: metadata.icon != nil,
                          executableUUID: metadata.executableUUID, urlSchemes: urlSchemes,
                          buildScheme: buildScheme, signer: metadata.signer,
                          app: app.flatMap { $0.isEmpty ? nil : $0 }, origin: origin, channel: channel,
                          buildVariant: metadata.buildVariant)
        try WireCoding.encoder().encode(build).write(to: destination.appendingPathComponent("build.json"), options: .atomic)
        prune(bundleID: metadata.bundleID, keeps: keeps, now: now)
        return build
    }

    /// Builds published before the server read executables' UUIDs or URL
    /// schemes: read now, from their package, and kept. How many were. (An
    /// Android build has neither.)
    @discardableResult
    public func fillIn() -> Int {
        var filled = 0
        for var build in all() where build.platform != "android" && (build.executableUUID == nil || build.urlSchemes == nil) {
            guard let package = package(build.id), let metadata = try? IPAMetadata.read(package) else { continue }
            build.executableUUID = build.executableUUID ?? metadata.executableUUID
            build.urlSchemes = metadata.urlSchemes
            guard let data = try? WireCoding.encoder().encode(build) else { continue }
            if (try? data.write(to: buildFolder(build.id).appendingPathComponent("build.json"), options: .atomic)) != nil { filled += 1 }
        }
        return filled
    }

    /// Where the build schemes' numbers are kept (SchemeNumbers).
    private var schemesFile: URL { folder.deletingLastPathComponent().appendingPathComponent("schemes.json") }

    /// This server's own release, the current one until Applications is
    /// released here.
    static let ownRelease = BuildSchemes.release(of: ApplicationsServer.version) ?? ApplicationsServer.version

    /// The release whose schemes builds are given: the newest of
    /// Applications' production iPhone builds published here (its betas
    /// set nothing), else this server's own.
    func currentRelease(_ numbers: SchemeNumbers) -> String {
        let published = all().filter { $0.platform == "ios" && $0.bundleID == BuildSchemes.applicationsBundleID && $0.channel == .production }
            .compactMap { BuildSchemes.release(of: $0.version) }
        return (published + [numbers.applications].compactMap { $0 }).max { ApplicationsServer.newer($1, $0) } ?? Self.ownRelease
    }

    /// The scheme an app's production build of a commit carries, given now
    /// under the current release, or the one the commit was given under it
    /// before. Applications needs none, nor does a beta's bundle id (a beta
    /// is never asked about): neither gets a number. Throws
    /// `SchemeNumbers.UsedUp` once the release's are given out.
    public func scheme(bundleID: String, commit: String) throws -> BuildSchemeAnswer {
        try SchemeNumbers.update(schemesFile) { numbers in
            let release = currentRelease(numbers)
            guard bundleID != BuildSchemes.applicationsBundleID, !BundleVariant.isBeta(bundleID) else {
                return BuildSchemeAnswer(release: release, scheme: nil)
            }
            guard let given = numbers.reserve(release: release, bundleID: bundleID, commit: commit) else {
                throw SchemeNumbers.UsedUp(release: release)
            }
            return BuildSchemeAnswer(release: release, scheme: BuildSchemes.scheme(release: release, number: given.number))
        }
    }

    /// The current release, and how many of its numbers are given.
    func schemesGiven() -> (release: String, given: Int) {
        let numbers = SchemeNumbers.load(schemesFile)
        let release = currentRelease(numbers)
        return (release, (numbers.releases[release]?.next ?? 1) - 1)
    }

    /// Whether a production iPhone build needs a scheme given here, or has
    /// what it needs: Applications' own needs none (its release is the
    /// server's from now on, if newer); one CI stamped keeps its own (noted
    /// in the log when it was not given to this app here).
    private func ownScheme(_ metadata: IPAMetadata) throws -> (needed: Bool, scheme: String?) {
        if metadata.bundleID == BuildSchemes.applicationsBundleID {
            if let release = BuildSchemes.release(of: metadata.version) {
                try SchemeNumbers.update(schemesFile) { $0.published(applications: release) }
            }
            return (false, nil)
        }
        if let stamped = metadata.urlSchemes.first(where: { BuildSchemes.parse($0) != nil }), let parsed = BuildSchemes.parse(stamped) {
            if !SchemeNumbers.load(schemesFile).gave(release: parsed.release, number: parsed.number, to: metadata.bundleID) {
                FileManager.default.standardError("applications-server: \(metadata.bundleID) \(metadata.version) carries \(stamped), "
                                                  + "which was not given to it here; published with it")
            }
            return (false, stamped)
        }
        return (true, nil)
    }

    /// The next number under the current release for an app's build of a
    /// commit (the one it was given, if it was); refused
    /// (PackageCheck.Refusal) once the release's are given out.
    private func reserveScheme(bundleID: String, commit: String?) throws -> (release: String, number: Int, fresh: Bool) {
        try SchemeNumbers.update(schemesFile) { numbers in
            let release = currentRelease(numbers)
            guard let given = numbers.reserve(release: release, bundleID: bundleID, commit: commit) else {
                throw PackageCheck.Refusal(SchemeNumbers.UsedUp(release: release).description)
            }
            return (release, given.number, given.fresh)
        }
    }

    /// A production iPhone build CI sent, signed by the server with the
    /// production identity, its scheme given and added as it is signed
    /// (unless it is Applications', or came stamped), and checked. A build
    /// that cannot be signed is refused, its number given back: unsigned,
    /// it would not install.
    private func signProduction(_ ipa: URL, metadata: IPAMetadata, commit: String?, signer: Signer) throws -> String? {
        let own = try ownScheme(metadata)
        guard own.needed else {
            try signer.sign(ipa: ipa, .production)
            try PackageCheck.verify(package: ipa, platform: "ios")
            return own.scheme
        }
        let given = try reserveScheme(bundleID: metadata.bundleID, commit: commit)
        let scheme = BuildSchemes.scheme(release: given.release, number: given.number)
        do {
            try signer.sign(ipa: ipa, .production, adding: [scheme])
            try PackageCheck.verify(package: ipa, platform: "ios")
            return scheme
        } catch {
            if given.fresh { _ = try? SchemeNumbers.update(schemesFile) { $0.giveBack(release: given.release, number: given.number) } }
            throw error
        }
    }

    /// Lets an app's builds go that are kept no more: of main's, all but
    /// the newest and those `keeps` holds on to (production's) once older
    /// than the retention; of each pull request's, all but its newest past
    /// its newest three, or older than the retention.
    private func prune(bundleID: String, keeps: (Build) -> Bool, now: Date) {
        let builds = all().filter { $0.bundleID == bundleID }
        let old = { (build: Build) in now.timeIntervalSince(build.published) > Self.retention(of: build) }
        let main = builds.filter { $0.origin?.pullRequest == nil && !Self.isAdHoc($0) }
        var gone = main.dropFirst().filter { !keeps($0) && old($0) }
        gone += builds.filter { Self.isAdHoc($0) && $0.origin?.pullRequest == nil && old($0) }
        for number in Set(builds.compactMap(\.origin?.pullRequest)) {
            let theirs = builds.filter { $0.origin?.pullRequest == number }
            gone += theirs.enumerated().dropFirst().filter { $0.offset >= Self.keptPerPullRequest || old($0.element) }.map(\.element)
        }
        for build in gone { try? FileManager.default.removeItem(at: buildFolder(build.id)) }
    }

    /// Every app's builds pruned (what aged past the retention since the
    /// last publish goes too).
    public func pruneAll(keeps: (Build) -> Bool, now: Date = Date()) {
        for bundleID in Set(all().map(\.bundleID)) { prune(bundleID: bundleID, keeps: keeps, now: now) }
    }

    /// A pull request's builds let go: it merged or closed.
    public func forget(pullRequest number: Int) -> Int {
        let gone = all().filter { $0.origin?.pullRequest == number }
        for build in gone { try? FileManager.default.removeItem(at: buildFolder(build.id)) }
        return gone.count
    }

    /// Every build of a bundle let go (an app retired, or renamed to
    /// another bundle id); how many.
    public func forget(bundleID: String) -> Int {
        let gone = all().filter { $0.bundleID == bundleID }
        for build in gone { try? FileManager.default.removeItem(at: buildFolder(build.id)) }
        return gone.count
    }

    private func buildFolder(_ id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }

    /// A build's id: when it came, then a few random letters.
    static func newID(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return formatter.string(from: now) + "-" + String((0..<6).map { _ in letters.randomElement() ?? "a" })
    }

    /// Only ids this store makes are looked up: no path in them.
    static func isID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 40 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } && id.allSatisfy(\.isASCII)
    }

    /// One past the highest build number of a version's builds that
    /// `matching` takes (an app's), a pull request's included; 1 for the
    /// first.
    func nextBuildNumber(version: String, matching: (Build) -> Bool) -> Int {
        (all().filter { $0.version == version && matching($0) }.compactMap { Int($0.buildNumber) }.max() ?? 0) + 1
    }
}
