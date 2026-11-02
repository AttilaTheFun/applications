// applications-server: Applications Server, its settings and builds, and the way to publish to it. It runs as a launchd
// service of its own (com.LoganShire.ApplicationsServer).
//
//   applications-server serve                    run the server (what the service runs)
//   applications-server install                  the service: this build copied to <data folder>/bin and run from there with
//                                                `serve`, at login and whenever it exits, in place of one installed before
//                                                (bazel run -c opt //server -- install); its log in ~/Library/Logs/Applications
//                                                Server; ~/.local/bin/applications-server a link to it, for the commands
//   applications-server restart                  the service stopped and started again (after a setting below)
//   applications-server uninstall                the service stopped and removed; the data folder is kept
//   applications-server publish <app.ipa | .zip | .dmg | .apk> [--notes <text> | --notes-file <notes.md>] [--app <name>]
//                                                [--code <connection code>]
//                                                publish a build by hand, always a beta, as it came; to this computer's server, or
//                                                another's by its code. Production comes only from a release's CI, with its OIDC token
//                                                (docs/CI.md): --release is refused. --app: the app it is a build of across platforms,
//                                                if not its own name. --commit <sha> [--branch <name>] [--pull-request <n>]: a branch's
//                                                build, kept with its pull request apart from main's
//   applications-server next-build <app> <version> [--commit <sha>]
//   applications-server next-version <app> <MAJOR.MINOR> [--commit <sha>]   the next build's version, MAJOR.MINOR.BUILD
//                                                the build number the version's next build takes (one past its highest
//                                                here); CI stamps it into each build before building it. With a commit:
//                                                kept as that commit's (asked again, the same), so every build of it has one.
//                                                CI on another computer asks over HTTPS with its OIDC token, for its token's
//                                                commit (POST /api/next-version, tools/ci/next_version.sh)
//   applications-server scheme <bundle id> --commit <sha>
//                                                the URL scheme a production iPhone build of the commit carries, which CI's
//                                                release job stamps into its Info.plist (CFBundleURLTypes) before building it, for
//                                                Applications to ask iOS whether it is installed: applications-<release>-build-<n>,
//                                                under the newest Applications release's (asked again, the same). Prints nothing
//                                                for Applications itself, which needs none, nor for a beta's bundle id, which is
//                                                never asked about; fails once the release's 49 are given out, until an
//                                                Applications release of a newer MAJOR.MINOR is published
//   applications-server password on | off        whether the API asks for the password (off: a server only your LAN or tailnet reaches)
//   applications-server app <bundle id> <app>    count a bundle id's builds as the app's, where their own name does not say
//                                                (an inbox upload can say it in its notes: a line `<!-- app: <app> -->`)
//   applications-server forget --pull-request <n> | --bundle <bundle id>
//                                                let a merged or closed pull request's builds go
//   applications-server code [--link | --qr <file.png>] [--beta] | --ci
//                                                the connection code the app is set up with (as a link, or a QR code to scan;
//                                                --beta: the link Applications β opens, applications-beta://). --ci: the code CI
//                                                publishes with (tools/ci/publish_from_ci.sh), its addresses and authority alone, no password
//   applications-server apns --key <AuthKey.p8> --key-id <id> --team-id <id>
//                                                keep the APNs key the server sends pushes with
//   applications-server repo <owner/repo> <bundle id>… | off
//                                                the production bundle ids (their betas' go with them) that repository's CI publishes
//                                                with its OIDC token, which the server signs (docs/CI.md); off: it publishes none
//   applications-server releaser <login> [off]   a GitHub login whose releases CI publishes as production (the repository owner's)
//   applications-server notary --key <AuthKey.p8> --key-id <id> --issuer <id>
//                                                keep the App Store Connect API key Mac apps are notarized with
//   applications-server oidc --audience <aud>    the audience CI asks GitHub's tokens for (applications-server unless set)
//   applications-server inbox <owner/repo> | off publish what agents elsewhere leave in that repo's draft release "inbox"
//   applications-server status                   what the server has: the service (loaded, its pid), whether its ports answer
//                                                as this server, its builds and settings
//
// The service is launchd's, so install, restart, uninstall and status are macOS's for now: on Linux they say so and
// fail, and `serve` is run some other way.

import ApplicationsProtocol
import ApplicationsPublish
import ApplicationsServer
import Foundation
import PipelineClient
import PipelineServer

let arguments = Array(CommandLine.arguments.dropFirst())
let usage = "applications-server serve | install | restart | uninstall | publish | next-build | next-version | scheme | code | password | app | forget | apns | inbox | repo | releaser | notary | oidc | status (main.swift says each)"
guard let command = arguments.first else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func say(_ message: String) { print(message) }

let paths = ServerPaths.standard
let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
let hostName = HostName.local
let service = ServerService.agent(paths: paths)

/// What the service commands say on Linux, where there is no launchd.
func noServiceHere() -> Never {
    fail("applications-server \(command): the service is launchd's, on macOS only for now; on Linux, run applications-server serve "
         + "under a service manager of your own until it has one (docs/APPLICATIONS_PLAN.md).")
}

do {
    switch command {
    case "serve":
        try await Serve.run(paths: paths, name: name, hostName: hostName)
    case "install":
        #if os(macOS)
        try paths.prepare()
        let standing = try service.install()
        // The commands on the PATH are the build that serves.
        let link = ServerService.commandLink()
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: service.binary)
        say("Applications Server is installed as \(service.label): \(standing).")
        say("It runs \(service.binary.path) serve; its log is \(service.log.path); \(link.path) links to it.")
        #else
        noServiceHere()
        #endif
    case "restart":
        #if os(macOS)
        guard service.standing().loaded else { fail("\(service.label) is not loaded: applications-server install") }
        say("\(service.label): \(try service.restart()).")
        #else
        noServiceHere()
        #endif
    case "uninstall":
        #if os(macOS)
        say(service.remove() ? "\(service.label) is stopped and removed; the data in \(paths.root.path) is kept."
                             : "\(service.label) was not installed.")
        #else
        noServiceHere()
        #endif
    case "publish":
        guard arguments.count >= 2 else {
            fail("applications-server publish <app.ipa | .zip | .dmg | .apk> [--notes <text> | --notes-file <notes.md>] [--app <app>] "
                 + "[--code <connection code>]")
        }
        guard !arguments.contains("--release") else { fail("--release is refused: " + BuildStore.productionIsCIs) }
        var notes = option("--notes") ?? ""
        if let file = option("--notes-file") {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { fail("Cannot read \(file)") }
            notes = text
        }
        // A branch's build (CI's :build:): its commit, branch and pull request.
        let origin = option("--commit").map { BuildOrigin(commit: $0, branch: option("--branch"), pullRequest: option("--pull-request").flatMap(Int.init)) }
        let build = try await Publish.run(ipa: URL(fileURLWithPath: arguments[1]), notes: notes, app: option("--app"), origin: origin,
                                          code: option("--code"), paths: paths, name: name)
        say("Published \(build.name) \(build.versionTitle) (\(build.id)), \((build.channel ?? .beta).title.lowercased())")
    case "code":
        let server = try ApplicationsServer(paths: paths, name: name)
        try await server.prepareTLS(local: LocalAddress.current(), hostName: hostName)
        // CI's: where the server is and its authority, no password (a job's
        // token is its permission).
        if arguments.contains("--ci") {
            say(try await server.ciCode().text)
            break
        }
        let text = try await server.connectionCode().text
        // Each of Applications' builds has a link scheme of its own, so one
        // installed beside the other opens its own links.
        let link = (arguments.contains("--beta") ? "applications-beta" : "applications") + "://connect?code=" + text
        if let file = option("--qr") {
            // The link as a QR code: scanned with the phone's camera, it
            // opens Applications with the server added.
            try QRImage.write(link, to: URL(fileURLWithPath: file))
            say("Wrote \(file): scan it with the phone's camera. It carries the password: delete it after.")
        } else {
            say(arguments.contains("--link") ? link : text)
        }
    case "apns":
        guard let key = option("--key"), let keyID = option("--key-id"), let teamID = option("--team-id") else {
            fail("applications-server apns --key <AuthKey.p8> --key-id <id> --team-id <id>")
        }
        let server = try ApplicationsServer(paths: paths, name: name)
        try await server.setAPNsKey(pem: try String(contentsOfFile: key, encoding: .utf8), keyID: keyID, teamID: teamID)
        say("The APNs key is kept; restart the server (applications-server restart) to send pushes with it.")
    case "repo":
        // applications-server repo <owner/repo> <bundle id>… | off
        guard arguments.count >= 3, arguments[1].split(separator: "/").count == 2,
              arguments[2...].allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.contains(" ") }) else {
            fail("applications-server repo <owner/repo> <bundle id>… | off")
        }
        let server = try ApplicationsServer(paths: paths, name: name)
        let off = arguments[2] == "off"
        try await server.setRepository(arguments[1], bundleIDs: off ? [] : Array(arguments[2...]))
        if off {
            say("\(arguments[1])'s CI publishes nothing here.")
        } else {
            let ids = await server.config.repositories[arguments[1]] ?? []
            say("\(arguments[1])'s CI publishes \(ids.joined(separator: ", ")) and their betas, signed here.")
        }
    case "releaser":
        // applications-server releaser <login> [off]
        guard arguments.count >= 2, !arguments[1].hasPrefix("-"), arguments.count == 2 || arguments[2] == "off" else {
            fail("applications-server releaser <login> [off]")
        }
        let server = try ApplicationsServer(paths: paths, name: name)
        let releases = arguments.count == 2
        try await server.setReleaser(arguments[1], releases)
        say(releases ? "\(arguments[1])'s releases are published as production." : "\(arguments[1])'s releases are not published.")
    case "notary":
        guard let key = option("--key"), let keyID = option("--key-id"), let issuer = option("--issuer") else {
            fail("applications-server notary --key <AuthKey.p8> --key-id <id> --issuer <id>")
        }
        let server = try ApplicationsServer(paths: paths, name: name)
        try await server.setNotaryKey(pem: try String(contentsOfFile: key, encoding: .utf8), keyID: keyID, issuer: issuer)
        say("The notary key is kept: Mac apps CI sends are notarized with it.")
    case "oidc":
        guard let audience = option("--audience"), !audience.isEmpty else { fail("applications-server oidc --audience <aud>") }
        let server = try ApplicationsServer(paths: paths, name: name)
        try await server.setOIDCAudience(audience)
        say("CI's tokens are taken for the audience \(audience).")
    case "app":
        guard arguments.count >= 3 else { fail("applications-server app <bundle id> <app>") }
        AppNames(file: paths.appNames).set(arguments[2...].joined(separator: " "), for: arguments[1])
        say("\(arguments[1])'s builds are \(arguments[2...].joined(separator: " "))'s.")
    case "password":
        guard arguments.count >= 2, ["on", "off"].contains(arguments[1]) else { fail("applications-server password on | off") }
        let server = try ApplicationsServer(paths: paths, name: name)
        try await server.setRequirePassword(arguments[1] == "on")
        say(arguments[1] == "on" ? "The API asks for the password." : "The API answers without the password; restart the server (applications-server restart).")
    case "forget":
        // applications-server forget --pull-request <n>: its builds let go (it merged or closed);
        // --bundle <id>: an app's, retired or renamed.
        if let bundle = option("--bundle") {
            say("\(BuildStore(folder: paths.builds).forget(bundleID: bundle)) builds of \(bundle) let go.")
            break
        }
        guard let number = option("--pull-request").flatMap(Int.init) else { fail("applications-server forget --pull-request <n> | --bundle <id>") }
        say("\(BuildStore(folder: paths.builds).forget(pullRequest: number)) builds of pull request #\(number) let go.")
    case "inbox":
        // applications-server inbox <owner/repo> | off
        guard arguments.count >= 2 else { fail("applications-server inbox <owner/repo> | off") }
        let server = try ApplicationsServer(paths: paths, name: name)
        let repository = arguments[1] == "off" ? "" : arguments[1]
        try await server.setInbox(repository)
        say(repository.isEmpty ? "The inbox is not watched." : "Builds left in \(repository)'s draft release \"inbox\" are published; restart the server (applications-server restart) to start watching.")
    case "next-build":
        guard arguments.count >= 3 else { fail("applications-server next-build <app> <version> [--commit <sha>]") }
        let server = try ApplicationsServer(paths: paths, name: name)
        say(String(await server.nextBuildNumber(app: arguments[1], version: arguments[2], commit: option("--commit"))))
    case "next-version":
        guard arguments.count >= 3 else { fail("applications-server next-version <app> <MAJOR.MINOR> [--commit <sha>]") }
        let server = try ApplicationsServer(paths: paths, name: name)
        say(await server.nextVersion(app: arguments[1], line: arguments[2], commit: option("--commit")))
    case "scheme":
        guard arguments.count >= 2, !arguments[1].hasPrefix("--"), let commit = option("--commit"), commit.count >= 7 else {
            fail("applications-server scheme <bundle id> --commit <sha>")
        }
        let server = try ApplicationsServer(paths: paths, name: name)
        let answer = try await server.buildScheme(bundleID: arguments[1], commit: commit)
        // The scheme alone on standard output, for CI to stamp; nothing
        // there for Applications, which needs none, or a beta.
        if let scheme = answer.scheme {
            say(scheme)
        } else if BundleVariant.isBeta(arguments[1]) {
            FileHandle.standardError.write(Data("\(arguments[1]) needs no scheme: a beta is never asked about (release \(answer.release)).\n".utf8))
        } else {
            FileHandle.standardError.write(Data("\(arguments[1]) needs no scheme: Applications knows its own version (release \(answer.release)).\n".utf8))
        }
    case "status":
        let server = try ApplicationsServer(paths: paths, name: name)
        try await server.prepareTLS(local: LocalAddress.current(), hostName: hostName)
        #if os(macOS)
        let config = await server.config
        let fingerprint = try CertificateAuthority(folder: paths.tls, name: "Applications").fingerprint()
        let standing = service.standing()
        say("Service: \(service.label), \(standing)" + (standing.loaded ? "" : " (applications-server install)"))
        say("Ports: " + (await ServicePorts.answers(http: config.httpPort, https: config.httpsPort, id: config.id, fingerprint: fingerprint)))
        say(await server.status())
        #else
        say(await server.status())
        noServiceHere()
        #endif
    default:
        fail("Unknown command \(command). " + usage)
    }
} catch {
    fail("applications-server: \(error)")
}
