import Foundation

/// What the server answers: a status, headers, and a body in memory or
/// a file sent as it is read.
public struct HTTPResponse: Sendable {
    public enum Body: Sendable {
        case data(Data)
        case file(URL, size: Int64)
    }

    public var status: Int
    public var headers: [String: String]
    public var body: Body

    public init(status: Int, headers: [String: String] = [:], body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var data: Data {
        if case .data(let data) = body { return data }
        return Data()
    }

    /// The value as JSON, in the server's own encoding (its dates, its keys).
    public static func json<T: Encodable>(_ value: T, status: Int = 200, encoder: JSONEncoder) -> HTTPResponse {
        let data = (try? encoder.encode(value)) ?? Data()
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: .data(data))
    }

    public static func text(_ text: String, status: Int, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": type], body: .data(Data(text.utf8)))
    }

    /// An error the app shows as it is: {"error": "..."}.
    public static func error(_ message: String, status: Int) -> HTTPResponse {
        .json(["error": message], status: status, encoder: JSONEncoder())
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}
