import Foundation
// URLSession, on the toolchain's Foundation (Linux, Windows).
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talking to the server: over the best of its paths that answers — this
/// computer itself (the server's own Mac), then the LAN (at home), then
/// the tailnet or the internet (away); each request with the password,
/// over HTTPS pinned to its authority.
public final class ServerClient: Sendable {
    public let code: ConnectionCode
    /// The platform's pin to the code's authority.
    public let pinning: any ServerPinning
    private let session: URLSession

    public init(code: ConnectionCode, pinning: any ServerPinning) {
        self.code = code
        self.pinning = pinning
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        session = pinning.session(configuration)
    }

    /// The code as the server reaching us at `address` now tells its
    /// addresses, when they are not the ones kept: a computer given a new
    /// LAN address by its router (after a restart) is found there again,
    /// and on its tailnet, its .local name and every other path it says.
    /// Nil when the kept code still says the same.
    public func freshCode(at address: String) async -> ConnectionCode? {
        guard let hello = try? await get(Hello.self, "/api/hello", at: address), hello.id == code.id,
              !hello.addresses.isEmpty, hello.addresses != code.addresses else { return nil }
        return ConnectionCode(id: code.id, name: hello.name.isEmpty ? code.name : hello.name, addresses: hello.addresses,
                              password: code.password, ca: code.ca)
    }

    /// What the server at `address` says it is, before any password.
    public func hello(at address: String) async -> Hello? {
        try? await get(Hello.self, "/api/hello", at: address)
    }

    /// The address that answers now, or nil when none does: every path
    /// asked at once for the server's hello (this computer's own too, which
    /// answers only on the server's Mac), and the best that answers taken:
    /// this computer at once; the LAN once this computer has had a moment;
    /// the tailnet or the internet once the others have had longer.
    public func reachableAddress() async -> String? { await probe().best }

    /// A path's answer to the hello, or the end of the wait for a better
    /// one.
    private enum Answer: Sendable {
        case answered(String)
        case failed(String, String)
        case waited
    }

    /// Every path asked at once, as `reachableAddress` does, with why each
    /// that did not answer did not (one still being asked when a good
    /// enough path answered is left out).
    public func probe() async -> PathProbe {
        let session = session
        let id = code.id
        return await Self.probe(Self.candidates(code.addresses)) { address in
            await Self.hello(at: address, id: id, session: session)
        }
    }

    /// One path asked for the server's hello: nil when this server answered
    /// there, else why not.
    private static func hello(at address: String, id: String, session: URLSession) async -> String? {
        guard let url = URL(string: address + "/api/hello") else { return "not an address" }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return "answered \(status)" }
            guard let hello = try? WireCoding.decoder().decode(Hello.self, from: data), hello.id == id else {
                return "another server answers there"
            }
            return nil
        } catch {
            return PathProbe.why(error)
        }
    }

    /// The choice of a path, given how one is asked (`ask`: nil when the
    /// server answered there, else why not): every path asked at once, and
    /// the best that answers taken — this computer at once, the LAN once
    /// this computer has had a moment, the tailnet or the internet once the
    /// others have had longer; and at once whenever no better path is
    /// still being asked (one refused or silent is not waited for).
    static func probe(_ addresses: [String], ask: @escaping @Sendable (String) async -> String?) async -> PathProbe {
        await withTaskGroup(of: Answer.self) { group in
            for address in addresses {
                group.addTask {
                    if let why = await ask(address) { return .failed(address, why) }
                    return .answered(address)
                }
            }
            var probe = PathProbe()
            var asking = Set(addresses)
            for await answer in group {
                switch answer {
                case .waited:
                    group.cancelAll()
                    return probe
                case .failed(let address, let why):
                    asking.remove(address)
                    probe.failures[address] = why
                case .answered(let answer):
                    asking.remove(answer)
                    if let kept = probe.best, rank(kept) <= rank(answer) { continue }
                    probe.best = answer
                    let wait = betterPathWait[rank(answer)]
                    if wait == 0 {
                        group.cancelAll()
                        return probe
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: wait)
                        return .waited
                    }
                }
                // Nothing better left to answer: no reason to wait.
                if let best = probe.best, !asking.contains(where: { rank($0) < rank(best) }) {
                    group.cancelAll()
                    return probe
                }
            }
            return probe
        }
    }

    /// How long a path of each rank waits for a better one to answer: this
    /// computer, none; the LAN, a moment for this computer; the tailnet or
    /// the internet, longer for the LAN.
    static let betterPathWait: [UInt64] = [0, 250_000_000, 800_000_000]

    /// The server's addresses, and this computer's own (127.0.0.1, at the
    /// same port), which only the server's own Mac answers on.
    public static func candidates(_ addresses: [String]) -> [String] {
        guard let port = addresses.lazy.compactMap({ URL(string: $0)?.port }).first else { return addresses }
        let own = "https://127.0.0.1:\(port)"
        return addresses.contains(own) ? addresses : [own] + addresses
    }

    /// How good a path is: 0 this computer itself, 1 the LAN (a private
    /// address, or a .local name), 2 the tailnet or the internet.
    public static func rank(_ address: String) -> Int {
        guard let host = URL(string: address)?.host?.lowercased() else { return 2 }
        if host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]" { return 0 }
        if isOverlay(address) { return 2 }
        if host.hasSuffix(".local") { return 1 }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return 2 }
        let isPrivate = parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 169 && parts[1] == 254)
        return isPrivate ? 1 : 2
    }

    /// GET a JSON value from `path` at `address`, with the password.
    public func get<T: Decodable>(_ type: T.Type, _ path: String, at address: String) async throws -> T {
        try WireCoding.decoder().decode(T.self, from: try await data(path, at: address))
    }

    public func data(_ path: String, at address: String) async throws -> Data {
        guard let url = URL(string: address + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + code.password, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ServerError(status: status, body: data) }
        return data
    }

    /// A file at `path` (a Mac app's .zip), saved to `file`.
    public func download(_ path: String, at address: String, to file: URL) async throws {
        guard let url = URL(string: address + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.setValue("Bearer " + code.password, forHTTPHeaderField: "Authorization")
        let (temporary, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ServerError(status: status, body: (try? Data(contentsOf: temporary)) ?? Data()) }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    /// POST a JSON value to `path` at `address`, with the password.
    public func post<T: Encodable>(_ value: T, to path: String, at address: String) async throws {
        guard let url = URL(string: address + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + code.password, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(value)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ServerError(status: status, body: data) }
    }

    /// POST a body already encoded to `path` at `address`, with the
    /// password: the answer's body.
    public func send(_ body: Data, to path: String, at address: String) async throws -> Data {
        guard let url = URL(string: address + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + code.password, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ServerError(status: status, body: data) }
        return data
    }

    /// Where the server's plain port is at the address that answered: the
    /// certificate authority's profile, for Safari.
    public static func profileURL(for address: String, httpPort: Int = 7460) -> URL? {
        guard let host = URL(string: address)?.host else { return nil }
        return URL(string: "http://\(host):\(httpPort)/")
    }

    public static func isOverlay(_ address: String) -> Bool {
        guard let host = URL(string: address)?.host else { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}
