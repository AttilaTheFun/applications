/// What a build is, by how it was published: a beta, built from a commit
/// (main's, or a branch's) and not tagged in a release; or production,
/// published by a release's CI (a `v*` tag released by a releaser). A
/// build's channel is its own, never its version's.
public enum ReleaseChannel: String, Codable, Sendable, CaseIterable {
    case beta
    case production

    public var title: String {
        switch self {
        case .beta: "Beta"
        case .production: "Production"
        }
    }

    /// "alpha", as the channel was named before (channels.json, and builds
    /// kept then), reads as beta.
    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let channel = name == "alpha" ? .beta : ReleaseChannel(rawValue: name) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath,
                                                                    debugDescription: "Not a channel: \(name)"))
        }
        self = channel
    }
}
