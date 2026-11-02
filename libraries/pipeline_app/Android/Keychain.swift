import PipelineHost

/// The server's connection code, on Android: in the host's store, sealed
/// with a key the Android Keystore holds and never lets out (as Apple's is
/// kept in the keychain). "" removes it. Asked by the store, on the main
/// actor, where the host is.
enum Keychain {
    static func get(_ account: String) -> String {
        MainActor.assumeIsolated { PipelineHostBox.current?.secret(key: account) ?? "" }
    }

    static func set(_ account: String, _ value: String) {
        MainActor.assumeIsolated { PipelineHostBox.current?.setSecret(key: account, value: value) }
    }
}
