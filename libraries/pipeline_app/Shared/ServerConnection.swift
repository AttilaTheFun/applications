import Foundation
import Observation
import PipelineClient

/// An app's server: its connection code, kept in the keychain; the path
/// that answers, the LAN's when it does, else the tailnet's, chosen again
/// when the device's network changes; and why it cannot be reached.
@MainActor
@Observable
final class ServerConnection {
    /// The server, as the app says it ("Applications Server").
    let serverName: String
    /// The kind of server it is, as its hello says ("applications"): a code
    /// for another kind is refused.
    let kind: String
    /// The app's link scheme: `<scheme>://connect?code=…` connects it. Its
    /// own, apart from the kind (`applications`).
    let scheme: String
    private(set) var code: ConnectionCode?
    private(set) var client: ServerClient?
    /// The address that answered last.
    private(set) var address: String?
    /// Why each path that did not answer the last time they were all asked
    /// did not (Settings says them beside "Not reached").
    private(set) var failures: [String: String] = [:]
    /// Why the server could not be reached or refused; nil when the last
    /// request went through.
    var problem: String?
    /// The code is another kind of server's: what to say instead.
    private(set) var wrongServer: String?
    /// The system refused this app the local network (Settings, Privacy &
    /// Security, Local Network): the LAN cannot be reached, only the tailnet.
    /// Said by a LAN path's own failure; the network's watch says it only
    /// rarely.
    var localNetworkDenied: Bool { networkSaysDenied || PathProbe(failures: failures).localNetworkDenied }
    private var networkSaysDenied = false
    /// Asked when the device's network changes, to ask the server again.
    var networkChanged: (@MainActor () -> Void)?
    private var network: NetworkWatch?
    private var lastNetwork: String?
    private static let codeAccount = "server"

    /// Takes the code kept, or one given at launch (`-<kind>.code <code>`,
    /// as a simulator is started for a look, or written to the app's
    /// defaults to pair it unattended) as if pasted. One written to the
    /// defaults is taken out of them once it is in the Keychain: the code
    /// carries the password.
    init(serverName: String, kind: String, scheme: String) {
        self.serverName = serverName
        self.kind = kind
        self.scheme = scheme
        if let given = UserDefaults.standard.string(forKey: kind + ".code"), ConnectionCode(parsing: given) != nil {
            Keychain.set(Self.codeAccount, given)
            UserDefaults.standard.removeObject(forKey: kind + ".code")
        }
        if let code = ConnectionCode(parsing: Keychain.get(Self.codeAccount)) { use(code) }
        network = NetworkWatch { [weak self] shape, denied in
            Task { @MainActor in self?.observe(shape, localNetworkDenied: denied) }
        }
    }

    private func observe(_ shape: String, localNetworkDenied denied: Bool) {
        networkSaysDenied = denied
        guard shape != lastNetwork else { return }
        let first = lastNetwork == nil
        lastNetwork = shape
        guard !first, code != nil else { return }
        address = nil
        networkChanged?()
    }

    private func use(_ code: ConnectionCode) {
        self.code = code
        client = ServerClient(code: code, pinning: ServerTrust(fingerprint: code.ca))
    }

    var unreachable: String { "The \(serverName) can't be reached. Check your network: away from home, Tailscale needs to be on." }

    var noLocalNetwork: String {
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "this app"
        return "\(app) may not use your local network, so the \(serverName) at home can't be reached: turn it on in Settings, Privacy & Security, Local Network, \(app)."
    }

    /// Takes a pasted code, or the whole link it came in: nil when it is
    /// one, else why not.
    func connect(_ text: String) -> String? {
        let pasted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inLink = URL(string: pasted).flatMap(code(in:))
        guard let code = ConnectionCode(parsing: inLink ?? pasted) else { return "That is not the \(serverName)'s connection code." }
        Keychain.set(Self.codeAccount, code.text)
        use(code)
        address = nil
        problem = nil
        return nil
    }

    /// The code a link (`<scheme>://connect?code=…`, what the server's
    /// `code --link` and `--qr` make) carries, if it is one.
    func code(in url: URL) -> String? {
        guard url.scheme == scheme, url.host() == "connect" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }

    func forget() {
        Keychain.set(Self.codeAccount, "")
        code = nil
        client = nil
        address = nil
        problem = nil
        wrongServer = nil
    }

    /// The path chosen afresh, the LAN's when it answers, else the
    /// tailnet's, and the code brought up to date with the addresses the
    /// server tells now; nil (and why) when none answers.
    func choosePath() async -> String? {
        guard let client else { return nil }
        let probe = await client.probe()
        // Cancelled (the view that asked went away): no word on the server.
        guard !Task.isCancelled else { return probe.best }
        failures = probe.failures
        guard let found = probe.best else {
            address = nil
            problem = localNetworkDenied ? noLocalNetwork : unreachable
            return nil
        }
        address = found
        // Another kind of server's code (each server's hello says which).
        if let theirs = await client.hello(at: found)?.kind, theirs != kind {
            wrongServer = "That is another server's code, not the \(serverName)'s: paste the code `\(kind)-server code` prints."
            problem = wrongServer
            return nil
        }
        wrongServer = nil
        if let fresh = await client.freshCode(at: found) {
            Keychain.set(Self.codeAccount, fresh.text)
            use(fresh)
        }
        return found
    }

    /// The server and the address that answered last; chosen again when
    /// there is none.
    func reachable() async -> (ServerClient, String)? {
        guard let client else { return nil }
        if let address { return (client, address) }
        let probe = await client.probe()
        if !Task.isCancelled { failures = probe.failures }
        guard let found = probe.best else {
            if !Task.isCancelled { problem = localNetworkDenied ? noLocalNetwork : unreachable }
            return nil
        }
        address = found
        return (client, found)
    }

    /// A request to the server, at the address that answered last; if that
    /// path no longer answers (the network changed under it), the path is
    /// chosen again and the request made once more there. One that goes
    /// through clears what was said of the server; one cancelled (its view
    /// went away) says nothing of it, and leaves the path as it was.
    func ask<T>(_ request: (ServerClient, String) async throws -> T) async throws -> T {
        guard let (client, address) = await reachable() else { throw Unreachable(words: unreachable) }
        do {
            return answered(try await request(client, address))
        } catch let error as URLError where error.code != .cancelled && !Task.isCancelled {
            self.address = nil
            guard let (client, again) = await reachable(), again != address else { throw Unreachable(words: unreachable) }
            return answered(try await request(client, again))
        }
    }

    /// The server answered: whatever was said of reaching it no longer holds
    /// (another kind of server's code still does).
    private func answered<T>(_ answer: T) -> T {
        if wrongServer == nil { problem = nil }
        return answer
    }

    struct Unreachable: Error, LocalizedError {
        let words: String
        var errorDescription: String? { words }
    }
}
