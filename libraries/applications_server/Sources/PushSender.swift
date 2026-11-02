import ApplicationsProtocol
import CryptoKit
import Foundation

/// Pushes to the app through APNs: signed with the team's APNs key (a
/// .p8, its id and the team's), one request per device, over HTTP/2.
public struct PushSender: Sendable {
    let pem: String
    let keyID: String
    let teamID: String

    public init(pem: String, keyID: String, teamID: String) throws {
        _ = try P256.Signing.PrivateKey(pemRepresentation: pem)
        self.pem = pem
        self.keyID = keyID
        self.teamID = teamID
    }

    /// The signed token APNs takes for up to an hour.
    func jwt(now: Date = Date()) throws -> String {
        func part(_ object: [String: Any]) -> String {
            Self.base64URL((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
        }
        let body = part(["alg": "ES256", "kid": keyID]) + "." + part(["iss": teamID, "iat": Int(now.timeIntervalSince1970)])
        let signature = try P256.Signing.PrivateKey(pemRepresentation: pem).signature(for: Data(body.utf8)).rawRepresentation
        return body + "." + Self.base64URL(signature)
    }

    /// The request for one notification to one device.
    /// `category` names the actions the notification offers (the app's
    /// Install, for a build).
    static func request(to device: DeviceRegistration, jwt: String, title: String, body: String, category: String? = nil,
                        data: [String: String]) -> URLRequest? {
        let host = device.environment == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(device.token)") else { return nil }
        var aps: [String: Any] = ["alert": ["title": title, "body": body], "sound": "default"]
        if let category { aps["category"] = category }
        var payload: [String: Any] = ["aps": aps]
        for (key, value) in data { payload[key] = value }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        request.setValue("bearer " + jwt, forHTTPHeaderField: "authorization")
        request.setValue(device.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        return request
    }

    /// Sends one notification to each device; the tokens APNs says are
    /// gone (the app deleted), to forget.
    public func send(to devices: [DeviceRegistration], title: String, body: String, category: String? = nil,
                     data: [String: String]) async -> [String] {
        guard let jwt = try? jwt() else { return [] }
        var gone: [String] = []
        for device in devices {
            guard let request = Self.request(to: device, jwt: jwt, title: title, body: body, category: category, data: data),
                  let (answer, response) = try? await URLSession.shared.data(for: request),
                  let status = (response as? HTTPURLResponse)?.statusCode else { continue }
            let reason = ((try? JSONSerialization.jsonObject(with: answer)) as? [String: Any])?["reason"] as? String
            if status == 410 || (status == 400 && ["BadDeviceToken", "DeviceTokenNotForTopic"].contains(reason ?? "")) {
                gone.append(device.token)
            } else if status != 200 {
                FileHandle.standardError.write(Data("applications-server: APNs answered \(status) \(reason ?? "") for \(device.name)\n".utf8))
            }
        }
        return gone
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
