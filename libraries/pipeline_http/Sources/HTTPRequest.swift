import Foundation

/// A request as the server reads it: its line, its headers (names in
/// lowercase), and its body, in memory or, for an upload, in a file.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data
    /// An upload's body, written to a file as it came.
    public var bodyFile: URL?
    /// From this computer itself (loopback).
    public var local: Bool
    /// Came in over HTTPS.
    public var secure: Bool

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data(),
                bodyFile: URL? = nil, local: Bool = false, secure: Bool = true) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.bodyFile = bodyFile
        self.local = local
        self.secure = secure
    }

    /// The path's parts: "/builds/a/b" is ["builds", "a", "b"].
    public var parts: [String] { path.split(separator: "/").map(String.init) }

    /// "host:port" as the client asked for it.
    public var host: String { headers["host"] ?? "" }

    /// Parses a request line and headers, "METHOD /path?query HTTP/1.1".
    static func head(_ text: String) -> (method: String, path: String, query: [String: String], headers: [String: String])? {
        let lines = text.components(separatedBy: "\r\n")
        let line = lines.first?.split(separator: " ") ?? []
        guard line.count >= 2 else { return nil }
        let target = String(line[1])
        let pieces = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if pieces.count == 2 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if let key = kv.first { query[key] = kv.count > 1 ? kv[1] : "" }
            }
        }
        var headers: [String: String] = [:]
        for header in lines.dropFirst() where !header.isEmpty {
            guard let colon = header.firstIndex(of: ":") else { continue }
            headers[header[..<colon].lowercased()] = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (String(line[0]), String(pieces[0]).removingPercentEncoding ?? String(pieces[0]), query, headers)
    }
}
