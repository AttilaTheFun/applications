import ApplicationsProtocol
import Foundation
import PipelineHTTP
import PipelineServer

/// A release made production by promotion, not by building it again: the
/// Alpha main's CI published of the release's commit is the build the owner
/// tested, so its release job asks the server to promote it. Each of the
/// commit's Alphas (its newest of each bundle id and platform) is copied,
/// its `BuildVariant` made Production, signed again for production (an
/// iPhone app with the distribution identity, its scheme given; a Mac app
/// with Developer ID, notarized) and kept as production beside the Alpha.
/// A Mac app's production build is given a disk image too (app.dmg: the
/// app and a link to /Applications, signed, notarized and stapled), which
/// the release job downloads to hand out with its release:
/// `GET /builds/<id>/<downloadKey>/app.dmg`.
///
///     POST /api/promote    Authorization: Bearer <the release job's OIDC token>, over HTTPS
///                          X-Applications-Notes (base64): the release's notes. The token's commit's Alphas of its
///                          repository's bundle ids, promoted: 201 with the production builds, those promoted before
///                          among them (asked again, the same). 401 when the token is refused; 403 when it is not a
///                          release's (a release branch's push, or a v* tag's, by a releaser: CIPolicy); 404 when the
///                          server keeps no Alpha of the commit (an Alpha is kept a week once it is not its app's
///                          newest).
///
/// An Android app's Alpha is not promoted: the server does not sign
/// Android apps, so it cannot stamp one; its release still builds it.
extension ApplicationsServer {
    /// A release job's promotion: its token checked, then its commit's
    /// Alphas promoted.
    func promoteFromCI(_ request: HTTPRequest, token: String) async -> HTTPResponse {
        var settings = currentSettings
        let claims: CIClaims
        do {
            claims = try await oidc.verify(token, audience: settings.oidcAudience)
        } catch {
            return .error("The token was refused: \(error)", status: 401)
        }
        settings = pinning(claims, settings)
        let notes = request.headers["x-applications-notes"].flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        do {
            let promoted = try await promote(claims: claims, settings: settings, notes: notes)
            return .json(promoted.map { listed($0) }, status: 201)
        } catch let refusal as CIPolicy.Refusal {
            return .error("Refused: \(refusal)", status: 403)
        } catch let missing as NothingToPromote {
            return .error(missing.description, status: 404)
        } catch {
            return .error("Not promoted: \(error)", status: 500)
        }
    }

    /// The token's commit's Alphas, promoted to production: each its newest
    /// of a bundle id and platform, one promoted before returned as it was.
    public func promote(claims: CIClaims, settings: ServerConfig? = nil, notes: String) async throws -> [Build] {
        let settings = settings ?? currentSettings
        let policy = settings.ciPolicy
        let (repository, ids) = try policy.configured(claims)
        // A release's token alone (CIPolicy): its release branch's push, or a
        // v* tag's, by a releaser; a releaser's other runs make betas.
        if let id = ids.first, try policy.channel(for: claims, bundleID: id) != .production {
            throw CIPolicy.Refusal("\(claims.ref) is not a release's: a release branch (release-MAJOR-MINOR) or a v* tag, pushed by a "
                                   + "releaser, is promoted")
        }
        let kept = builds.all().filter { $0.origin?.commit == claims.sha && ids.contains($0.productionBundleID) }
        var alphas: [Build] = []
        for build in kept where build.buildVariant == "Alpha" && ["ios", "macos"].contains(build.platform) {
            if !alphas.contains(where: { $0.bundleID == build.bundleID && $0.platform == build.platform }) { alphas.append(build) }
        }
        guard !alphas.isEmpty else {
            throw NothingToPromote("No Alpha of \(claims.sha) is kept here for \(repository) (an iPhone or Mac app's, published by "
                                   + "main's CI; an Alpha is kept a week once it is not its app's newest)")
        }
        // Every Alpha's channel decided before any is signed: a token that
        // may not release one refuses them all.
        for alpha in alphas { _ = try policy.channel(for: claims, bundleID: alpha.bundleID) }
        let signer = signer(settings)
        let builds = builds
        var promoted: [Build] = []
        for alpha in alphas {
            if let before = kept.first(where: { $0.channel == .production && $0.bundleID == alpha.bundleID && $0.platform == alpha.platform }) {
                // Promoted before this server made disk images: its disk image
                // made now, of the production build kept, so asking again
                // gives the release what it lacked.
                if before.platform == "macos", builds.diskImage(before.id) == nil, let package = builds.package(before.id) {
                    let dmg = try await Self.offActor { () throws -> URL in
                        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("promote-" + UUID().uuidString + ".dmg")
                        if case .skipped(let why) = try signer.diskImage(ofMacZip: package, volume: before.name, to: dmg) {
                            FileManager.default.standardError("applications-server: \(before.bundleID) \(before.version)'s disk image is "
                                                              + "signed, not notarized: \(why)")
                        }
                        return dmg
                    }
                    try builds.keepDiskImage(dmg, for: before.id)
                    FileManager.default.standardError("applications-server: \(before.bundleID) \(before.versionTitle) (macos), promoted "
                                                      + "before, given its disk image")
                }
                promoted.append(before)
                continue
            }
            guard let package = builds.package(alpha.id) else { throw NothingToPromote("\(alpha.bundleID) \(alpha.versionTitle)'s package is gone") }
            let readied = try await Self.offActor { () throws -> (readied: Readied, diskImage: URL?) in
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("promote-" + UUID().uuidString)
                    .appendingPathExtension(package.pathExtension)
                try FileManager.default.copyItem(at: package, to: file)
                try VariantStamp.stamp(file, platform: alpha.platform, variant: "Production")
                let metadata = try IPAMetadata.read(file)
                try CIPolicy.checkVariant(metadata.buildVariant, version: metadata.version, channel: .production, claims: claims)
                let origin = BuildOrigin(commit: claims.sha)
                let buildScheme = try builds.ready(file, metadata: metadata, channel: .production, commit: origin.commit, signer: signer)
                var diskImage: URL?
                if alpha.platform == "macos" {
                    let dmg = file.deletingPathExtension().appendingPathExtension("dmg")
                    if case .skipped(let why) = try signer.diskImage(ofMacZip: file, volume: metadata.name, to: dmg) {
                        FileManager.default.standardError("applications-server: \(metadata.bundleID) \(metadata.version)'s disk image is "
                                                          + "signed, not notarized: \(why)")
                    }
                    diskImage = dmg
                }
                return (Readied(file: file, metadata: metadata, channel: .production, origin: origin, buildScheme: buildScheme), diskImage)
            }
            let channels = channels.snapshot(names: appNames.all())
            let build = try builds.keep(readied.readied.file, metadata: readied.readied.metadata, buildScheme: readied.readied.buildScheme,
                                        notes: notes.isEmpty ? alpha.notes : notes, app: alpha.app, origin: readied.readied.origin,
                                        channel: .production) { channels.channel(of: $0) == .production }
            if let dmg = readied.diskImage { try builds.keepDiskImage(dmg, for: build.id) }
            FileManager.default.standardError("applications-server: \(claims.repository)'s run \(claims.runID) (\(claims.workflowRef), "
                                              + "\(claims.eventName) by \(claims.actor)) promoted \(alpha.bundleID) "
                                              + "\(alpha.versionTitle) (\(alpha.platform)) to production")
            await announce(build)
            promoted.append(build)
        }
        for skipped in kept where skipped.buildVariant == "Alpha" && skipped.platform == "android" {
            FileManager.default.standardError("applications-server: \(skipped.bundleID) \(skipped.versionTitle) (android) is not "
                                              + "promoted: the server does not sign Android apps")
        }
        return promoted
    }

    /// Why nothing was promoted: the commit has no Alpha here.
    struct NothingToPromote: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// An app's `BuildVariant` (its Info.plist's) changed in its package, in
/// place: an .ipa's app, or a Mac app's .zip. Its signature no longer
/// holds, so it is signed again after (a Mac app's stapled ticket taken
/// out with it).
enum VariantStamp {
    static func stamp(_ package: URL, platform: String, variant: String) throws {
        let work = try Signer.workFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let root = work.appendingPathComponent("package", isDirectory: true)
        try ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", package.path, root.path])
        let folder = platform == "ios" ? root.appendingPathComponent("Payload") : root
        guard let name = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).first(where: { $0.hasSuffix(".app") }) else {
            throw PackageCheck.Refusal("No app in it")
        }
        let app = folder.appendingPathComponent(name)
        let contents = platform == "ios" ? app : app.appendingPathComponent("Contents")
        let plist = contents.appendingPathComponent("Info.plist")
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: &format) as? [String: Any] else {
            throw PackageCheck.Refusal("\(name)'s Info.plist is not a dictionary")
        }
        info["BuildVariant"] = variant
        try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0).write(to: plist, options: .atomic)
        if platform == "macos" { try? FileManager.default.removeItem(at: contents.appendingPathComponent("CodeResources")) }
        let stamped = work.appendingPathComponent("stamped.zip")
        if platform == "ios" {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            try ProcessRunner.run("/usr/bin/zip", ["-q", "-r", "-y", "-X", stamped.path] + entries, in: root)
        } else {
            try ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, stamped.path])
        }
        _ = try FileManager.default.replaceItemAt(package, withItemAt: stamped)
    }
}
