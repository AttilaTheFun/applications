import CryptoKit
import Foundation
import PipelineServer

/// The key a build's install links carry: made from the server's
/// password and the build's id, so it is the same each time and no one
/// without the password can make it. iOS fetches the
/// manifest and the .ipa without the app's password; the links are the
/// permission instead.
public enum DownloadKey {
    public static func make(password: String, build: String) -> String {
        let digest = HMAC<SHA256>.authenticationCode(for: Data(build.utf8), using: SymmetricKey(data: Data(password.utf8)))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// Whether `key` is the build's, compared in constant time.
    public static func matches(_ key: String, password: String, build: String) -> Bool {
        ConstantTime.equal(key, make(password: password, build: build))
    }
}
