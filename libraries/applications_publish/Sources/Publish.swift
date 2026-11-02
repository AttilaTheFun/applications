import ApplicationsProtocol
import ApplicationsServer
import Foundation
import PipelineClient
import PipelineServer

/// Publishing a build: the package posted to Applications Server, on this
/// computer (by its loopback, no password) or another (by its connection
/// code). What `applications-server publish` does: a beta, always
/// (production comes only from a release's CI).
public enum Publish {
    public static func run(ipa: URL, notes: String, app: String? = nil, origin: BuildOrigin? = nil, code: String?,
                           paths: ServerPaths, name: String) async throws -> Build {
        guard FileManager.default.fileExists(atPath: ipa.path) else { throw Failure("No such file: \(ipa.path)") }
        let target: (addresses: [String], password: String, fingerprint: String)
        if let code {
            guard let parsed = ConnectionCode(parsing: code) else { throw Failure("That is not a connection code") }
            target = (parsed.addresses, parsed.password, parsed.ca)
        } else {
            let config = try ServerConfig.loadOrCreate(at: paths.config, name: name)
            let fingerprint = try CertificateAuthority(folder: paths.tls, name: "Applications").fingerprint()
            target = (["https://127.0.0.1:\(config.httpsPort)"], "", fingerprint)
        }
        let session = URLSession(configuration: .ephemeral, delegate: PinnedTrust(fingerprint: target.fingerprint), delegateQueue: nil)
        var failures: [String] = []
        for address in target.addresses {
            guard let url = URL(string: address + ApplicationsServer.publishPath) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 600)
            request.httpMethod = "POST"
            if !target.password.isEmpty { request.setValue("Bearer " + target.password, forHTTPHeaderField: "Authorization") }
            request.setValue(Data(notes.utf8).base64EncodedString(), forHTTPHeaderField: "X-Applications-Notes")
            if let app, !app.isEmpty { request.setValue(Data(app.utf8).base64EncodedString(), forHTTPHeaderField: "X-Applications-App") }
            if let origin {
                request.setValue(origin.commit, forHTTPHeaderField: "X-Applications-Commit")
                if let branch = origin.branch { request.setValue(Data(branch.utf8).base64EncodedString(), forHTTPHeaderField: "X-Applications-Branch") }
                if let number = origin.pullRequest { request.setValue(String(number), forHTTPHeaderField: "X-Applications-Pull-Request") }
            }
            do {
                let (data, response) = try await session.upload(for: request, fromFile: ipa)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 201 else {
                    let said = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "status \(status)"
                    throw Failure(said)
                }
                return try WireCoding.decoder().decode(Build.self, from: data)
            } catch let failure as Failure {
                throw failure
            } catch {
                failures.append("\(address): \(error.localizedDescription)")
            }
        }
        throw Failure("The update server was not reached: " + failures.joined(separator: "; "))
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }
}
