import Foundation

/// The server said no: its status, and the error it gave.
public struct ServerError: Error, LocalizedError {
    public let status: Int
    public let message: String

    public init(status: Int, body: Data) {
        self.status = status
        message = (try? JSONDecoder().decode([String: String].self, from: body))?["error"] ?? "The server answered \(status)"
    }

    public var errorDescription: String? { message }
}
