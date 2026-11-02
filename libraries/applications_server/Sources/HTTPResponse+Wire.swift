import ApplicationsProtocol
import Foundation
import PipelineClient
import PipelineHTTP

extension HTTPResponse {
    /// The value as JSON in the wire's encoding, which the apps decode.
    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        json(value, status: status, encoder: WireCoding.encoder())
    }
}
