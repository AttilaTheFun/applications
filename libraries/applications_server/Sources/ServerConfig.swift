import Foundation
import PipelineServer

/// The server's settings, kept in config.json (this user's alone): who it
/// is, its password, its ports, the APNs key's ids (the key itself is
/// apns.p8 beside it), and what CI may publish with its token and how it is
/// notarized (the notary key is notary.p8 beside it). A setting it no
/// longer has is read past, and goes at the next save.
public struct ServerConfig: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var password: String
    /// Plain HTTP: the certificate authority's profile, and nothing else.
    public var httpPort: UInt16
    /// HTTPS: everything.
    public var httpsPort: UInt16
    public var apnsKeyID: String
    public var apnsTeamID: String
    /// The GitHub repository (owner/name) whose draft release "inbox"
    /// agents on other computers leave builds in; empty when none is
    /// watched (`InboxPoller`).
    public var inbox: String
    /// Whether the API asks for the password. A server only your LAN or
    /// your own tailnet reaches may do without (`applications-server password
    /// off`); download links keep their keys either way.
    public var requirePassword: Bool
    /// The repositories (owner/name) whose CI publishes with its OIDC
    /// token, each with the production bundle ids it publishes (their
    /// betas' go with them): `applications-server repo`.
    public var repositories: [String: [String]]
    /// Each repository's number at GitHub (`repository_id`), by its name in
    /// lowercase: pinned by its first token here, and checked on every one
    /// after, so a repository given the name later (the first renamed or
    /// deleted) publishes nothing. `applications-server repo` again lets go
    /// of it.
    public var repositoryIDs: [String: String]
    /// The GitHub logins whose releases CI publishes as production:
    /// `applications-server releaser`.
    public var releasers: [String]
    /// The audience CI asks GitHub's tokens for: `applications-server oidc`.
    public var oidcAudience: String
    /// The App Store Connect API key's id and issuer, which notarize Mac
    /// apps (the key is notary.p8): `applications-server notary`.
    public var notaryKeyID: String
    public var notaryIssuer: String

    /// The ports, unless config.json names others.
    public static let defaultHTTPPort: UInt16 = 7460
    public static let defaultHTTPSPort: UInt16 = 7461

    public init(id: String, name: String, password: String, httpPort: UInt16 = ServerConfig.defaultHTTPPort,
                httpsPort: UInt16 = ServerConfig.defaultHTTPSPort, apnsKeyID: String = "", apnsTeamID: String = "", inbox: String = "",
                requirePassword: Bool = true, repositories: [String: [String]] = [:], repositoryIDs: [String: String] = [:],
                releasers: [String] = [],
                oidcAudience: String = GitHubOIDC.defaultAudience, notaryKeyID: String = "", notaryIssuer: String = "") {
        self.id = id
        self.name = name
        self.password = password
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.apnsKeyID = apnsKeyID
        self.apnsTeamID = apnsTeamID
        self.inbox = inbox
        self.requirePassword = requirePassword
        self.repositories = repositories
        self.repositoryIDs = repositoryIDs
        self.releasers = releasers
        self.oidcAudience = oidcAudience
        self.notaryKeyID = notaryKeyID
        self.notaryIssuer = notaryIssuer
    }

    /// What a server from before a setting kept reads as that setting's
    /// default, never as a config to make again (a new password).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        password = try c.decode(String.self, forKey: .password)
        httpPort = try c.decodeIfPresent(UInt16.self, forKey: .httpPort) ?? Self.defaultHTTPPort
        httpsPort = try c.decodeIfPresent(UInt16.self, forKey: .httpsPort) ?? Self.defaultHTTPSPort
        apnsKeyID = try c.decodeIfPresent(String.self, forKey: .apnsKeyID) ?? ""
        apnsTeamID = try c.decodeIfPresent(String.self, forKey: .apnsTeamID) ?? ""
        inbox = try c.decodeIfPresent(String.self, forKey: .inbox) ?? ""
        requirePassword = try c.decodeIfPresent(Bool.self, forKey: .requirePassword) ?? true
        repositories = try c.decodeIfPresent([String: [String]].self, forKey: .repositories) ?? [:]
        repositoryIDs = try c.decodeIfPresent([String: String].self, forKey: .repositoryIDs) ?? [:]
        releasers = try c.decodeIfPresent([String].self, forKey: .releasers) ?? []
        oidcAudience = try c.decodeIfPresent(String.self, forKey: .oidcAudience) ?? GitHubOIDC.defaultAudience
        notaryKeyID = try c.decodeIfPresent(String.self, forKey: .notaryKeyID) ?? ""
        notaryIssuer = try c.decodeIfPresent(String.self, forKey: .notaryIssuer) ?? ""
    }

    /// As kept now, read again: what CI may publish is read at each of its
    /// publishes, so `repo`, `releaser`, `oidc` and `notary` need no
    /// restart.
    static func load(_ url: URL) -> ServerConfig? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ServerConfig.self, from: $0) }
    }

    /// As kept, or made and kept the first time.
    public static func loadOrCreate(at url: URL, name: String) throws -> ServerConfig {
        if let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(ServerConfig.self, from: data) {
            return config
        }
        let config = ServerConfig(id: UUID().uuidString.lowercased(), name: name, password: ServerPassword.make())
        try config.save(to: url)
        return config
    }

    /// What CI may publish here, as these settings say.
    public var ciPolicy: CIPolicy { CIPolicy(repositories: repositories, releasers: releasers, repositoryIDs: repositoryIDs) }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
