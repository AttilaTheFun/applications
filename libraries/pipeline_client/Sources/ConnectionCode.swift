import Foundation

/// Everything the app needs to reach a server, as one string to paste:
/// its id and name, every address, the password, and the fingerprint of
/// the certificate authority its HTTPS certificate comes from (so the app
/// trusts that server and no other before the authority is installed).
public struct ConnectionCode: Codable, Sendable, Hashable {
    public var v = 1
    public var id: String
    public var name: String
    public var addresses: [String]
    public var password: String
    /// SHA-256 of the authority's certificate (DER), lowercase hex.
    public var ca: String

    public init(id: String, name: String, addresses: [String], password: String, ca: String) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.password = password
        self.ca = ca
    }

    /// base64url of its JSON, no padding.
    public var text: String {
        let data = (try? Self.encoder.encode(self)) ?? Data()
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A pasted code (spaces and line breaks around it ignored), or nil.
    public init?(parsing text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body), let code = try? JSONDecoder().decode(Self.self, from: data),
              !code.addresses.isEmpty, !code.password.isEmpty, !code.ca.isEmpty else { return nil }
        self = code
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
