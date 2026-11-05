import ApplicationsProtocol
import Foundation
import PipelineClient
import PipelineHTTP

extension ApplicationsServer {
    /// Every request, to its route. The plain HTTP port answers only what
    /// a device needs before it trusts the certificate authority.
    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let parts = request.parts
        switch (request.method, parts.first ?? "") {
        case ("GET", "ca.mobileconfig"), ("HEAD", "ca.mobileconfig"): return profile()
        case ("GET", ""): return welcome(request)
        case ("GET", "api") where parts.count == 2 && parts[1] == "hello": return .json(hello)
        default: break
        }
        guard request.secure else {
            return .error("Use HTTPS, on port \(config.httpsPort)", status: 404)
        }
        switch (request.method, parts.first ?? "") {
        case ("GET", "builds"), ("HEAD", "builds"): return download(parts, host: request.host)
        case (_, "api"): return await api(request, parts: Array(parts.dropFirst()))
        default: return .error("Nothing here", status: 404)
        }
    }

    private func api(_ request: HTTPRequest, parts: [String]) async -> HTTPResponse {
        // A CI job publishes with its OIDC token in place of the password,
        // which decides what it may publish and as what, and the server
        // signs it; it asks for its build's version with the same token
        // before it builds (ApplicationsServer+CI), and a release's job
        // has its commit's Alphas promoted (ApplicationsServer+Promotion).
        if request.method == "POST", let token = Self.bearer(request), GitHubOIDC.isToken(token) {
            switch parts {
            case ["publish"]: return await publishFromCI(request, token: token)
            case ["next-version"]: return await nextVersionFromCI(request, token: token)
            case ["promote"]: return await promoteFromCI(request, token: token)
            default: break
            }
        }
        // Publishing from this computer itself, and asking for a build's
        // version or scheme before it, need no password: whatever can reach
        // the loopback can read the password file anyway.
        let publishing = request.method == "POST" && [["publish"], ["build-scheme"], ["next-version"]].contains(parts)
        guard authorized(request) || (publishing && request.local) else { return .error("The password is wrong", status: 401) }
        switch (request.method, parts.first ?? "") {
        // The iPhone app's builds unless another platform is asked for
        // (`?platform=macos`, the Mac app's): an earlier iPhone app asks
        // without one.
        // Each bundle id's builds apart (what is installed is told apart by
        // it): a beta's `<id>.Beta` is not its production's `<id>`.
        case ("GET", "apps"):
            let channels = channels.snapshot(names: appNames.all())
            return .json(builds.apps(platform: request.query["platform"] ?? "ios").map { app in
                AppBuilds(bundleID: app.bundleID, name: app.name, builds: app.builds.map { listed($0, channels: channels) })
            })
        // A commit's builds (`?commit=`, its sha or the start of it), the
        // newest first.
        case ("GET", "builds") where parts.count == 1:
            guard let commit = request.query["commit"], commit.count >= 7 else { return .error("A commit is needed", status: 400) }
            return .json(builds(ofCommit: commit))
        case ("GET", "builds") where parts.count == 2:
            guard let build = builds.build(parts[1]) else { return .error("No such build", status: 404) }
            return .json(listed(build))
        case ("GET", "builds") where parts.count == 3 && parts[2] == "icon":
            guard let icon = builds.icon(parts[1]) else { return .error("No icon", status: 404) }
            return HTTPResponse(status: 200, headers: ["Content-Type": "image/png"], body: .data(icon))
        case ("GET", "catalog"): return catalogAnswer()
        case ("GET", "build-number"):
            guard let commit = request.query["commit"], commit.count >= 7 else { return .error("A commit is needed", status: 400) }
            return .json(buildNumbers(commit: commit))
        // A BuildSchemeRequest: the scheme CI stamps into the app's
        // production build of the commit before building it
        // (`applications-server scheme` on this computer). Refused once the
        // release's are given out.
        case ("POST", "build-scheme"):
            guard let asked = try? WireCoding.decoder().decode(BuildSchemeRequest.self, from: request.body),
                  !asked.bundleID.isEmpty, asked.commit.count >= 7 else {
                return .error("A bundle id and a commit are needed", status: 400)
            }
            do {
                return .json(try buildScheme(bundleID: asked.bundleID, commit: asked.commit))
            } catch let usedUp as SchemeNumbers.UsedUp {
                return .error(usedUp.description, status: 409)
            } catch {
                return .error("The scheme was not given: \(error)", status: 500)
            }
        // A NextVersionRequest: the version a build of the app's line takes,
        // MAJOR.MINOR.BUILD (`applications-server next-version` on this
        // computer), kept as the commit's when one is given: by hand, with
        // the password. CI asks with its token instead, for its token's
        // commit (ApplicationsServer+CI).
        case ("POST", "next-version"):
            guard let asked = Self.versionRequest(request), asked.commit.map({ $0.count >= 7 }) ?? true else {
                return .error("An app and a line (MAJOR.MINOR) are needed, and a commit of seven characters or more if any", status: 400)
            }
            return .json(NextVersionAnswer(version: nextVersion(app: asked.app, line: asked.line, commit: asked.commit)))
        case ("POST", "devices"):
            guard let device = try? JSONDecoder().decode(DeviceRegistration.self, from: request.body),
                  !device.token.isEmpty, device.token.allSatisfy(\.isHexDigit), !device.topic.isEmpty else {
                return .error("Not a device registration", status: 400)
            }
            devices.register(device)
            return .json(["ok": true])
        // A beta, always: production comes only from a release's CI, with
        // its token (above). A publish that asks for a release
        // (`X-Applications-Release: true`, what an earlier `publish
        // --release` sent) is refused, saying so.
        case ("POST", "publish"):
            if let asked = request.headers["x-applications-release"], ["true", "yes", "1"].contains(asked.lowercased()) {
                return .error("Refused: " + BuildStore.productionIsCIs, status: 403)
            }
            guard let file = request.bodyFile else { return .error("Post the .ipa, .zip, .dmg or .apk as the body", status: 400) }
            let notes = request.headers["x-applications-notes"].flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let app = request.headers["x-applications-app"].flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
            let origin = request.headers["x-applications-commit"].map { commit in
                BuildOrigin(commit: commit,
                            branch: request.headers["x-applications-branch"].flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) },
                            pullRequest: request.headers["x-applications-pull-request"].flatMap(Int.init))
            }
            do {
                return .json(listed(try await publish(package: file, notes: notes, app: app, origin: origin)), status: 201)
            } catch let refusal as PackageCheck.Refusal {
                // A package read, that a device would refuse: why, alone.
                return .error("Refused: \(refusal)", status: 400)
            } catch {
                return .error("Not an .ipa, a Mac app or an .apk this server reads: \(error)", status: 400)
            }
        // A promoted Mac build's notarized disk image (ApplicationsServer+Promotion).
        case "app.dmg":
            guard let dmg = builds.diskImage(build.id) else { return .error("No disk image", status: 404) }
            let size = ((try? FileManager.default.attributesOfItem(atPath: dmg.path)[.size]) as? NSNumber)?.int64Value ?? 0
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/x-apple-diskimage"], body: .file(dmg, size: size))
        default:
            return .error("Nothing here", status: 404)
        }
    }

    /// /builds/<id>/<key>/manifest.plist and /builds/<id>/<key>/app.ipa:
    /// what iOS fetches, with the key as the permission; and
    /// /builds/<id>/<key>/app.zip or app.apk, what the Mac app or the
    /// Android app downloads.
    private func download(_ parts: [String], host: String) -> HTTPResponse {
        guard parts.count == 4, let build = builds.build(parts[1]),
              DownloadKey.matches(parts[2], password: config.password, build: build.id) else {
            return .error("No such build", status: 404)
        }
        switch parts[3] {
        case "manifest.plist":
            return manifest(build: build.id, key: parts[2], host: host)
        case "app.ipa", "app.zip", "app.apk":
            guard let package = builds.package(build.id), package.lastPathComponent == parts[3] else {
                return .error("No such build", status: 404)
            }
            let type = parts[3] == "app.apk" ? "application/vnd.android.package-archive" : "application/octet-stream"
            return HTTPResponse(status: 200, headers: ["Content-Type": type], body: .file(package, size: build.size))
        default:
            return .error("Nothing here", status: 404)
        }
    }

    /// The manifest for a build, its .ipa named at the host the request
    /// came to, so iOS fetches it the same way.
    public func manifest(build id: String, key: String, host: String) -> HTTPResponse {
        guard let build = builds.build(id), DownloadKey.matches(key, password: config.password, build: id) else {
            return .error("No such build", status: 404)
        }
        let ipa = "https://\(host)/builds/\(id)/\(key)/app.ipa"
        return HTTPResponse(status: 200, headers: ["Content-Type": "text/xml"],
                            body: .data(InstallManifest.plist(ipaURL: ipa, bundleID: build.bundleID, version: build.version, title: build.name)))
    }

    private func profile() -> HTTPResponse {
        guard let data = try? authority.profile(serverID: config.id, title: config.name, purpose: "Lets this device install builds from Applications Server on \(config.name).") else {
            return .error("No certificate authority yet", status: 500)
        }
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/x-apple-aspen-config",
                                                   "Content-Disposition": "attachment; filename=\"Applications.mobileconfig\""],
                            body: .data(data))
    }

    /// A page for Safari: what this is, and the profile to install.
    private func welcome(_ request: HTTPRequest) -> HTTPResponse {
        .text("""
        <!doctype html><meta name="viewport" content="width=device-width"><title>Applications Server</title>
        <body style="font: 17px -apple-system; margin: 24px; line-height: 1.4">
        <h2>Applications Server on \(config.name)</h2>
        <p>To install builds from this server, this device trusts its certificate authority, once:</p>
        <ol><li><a href="/ca.mobileconfig">Download the profile</a>, then install it in Settings → General → VPN &amp; Device Management.</li>
        <li>Turn it on in Settings → General → About → Certificate Trust Settings.</li></ol>
        </body>
        """, status: 200, type: "text/html; charset=utf-8")
    }
}
