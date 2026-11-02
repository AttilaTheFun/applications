import Foundation
import Network
import Security

/// One port the server listens on, plain or TLS, and each connection to
/// it served: the request read (an upload streamed to a file), handed to
/// `handle`, the answer written, the connection closed. Everything here
/// runs on the listener's own queue, outside the main actor.
public final class HTTPListener: Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue

    /// The largest body read into memory; anything posted to `uploadPath`
    /// goes to a file instead, up to `uploadLimit`.
    static let memoryLimit = 1 << 20
    static let uploadLimit: Int64 = 4 << 30

    /// Listens on `port`, with TLS when an identity is given (and the
    /// certificates to send with it, the chain's authority).
    public nonisolated init(port: UInt16, identity: (SecIdentity, SecCertificate)?, uploads: URL, uploadPath: String,
                            handle: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) throws {
        let parameters: NWParameters
        if let (identity, authority) = identity {
            let tls = NWProtocolTLS.Options()
            guard let local = sec_identity_create_with_certificates(identity, [authority] as CFArray) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        parameters.allowLocalEndpointReuse = true
        // IPv4 only: a dual-stack listener on a Mac with Tailscale does not
        // answer at the computer's own tailnet address.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw CocoaError(.featureUnsupported) }
        listener = try NWListener(using: parameters, on: endpointPort)
        queue = DispatchQueue(label: "pipeline.http.\(port)")
        let secure = identity != nil
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            Task { await Self.serve(connection, queue: queue, secure: secure, uploads: uploads, uploadPath: uploadPath, handle: handle) }
        }
    }

    public nonisolated func start(failed: @escaping @Sendable (String) -> Void) {
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { failed(String(describing: error)) }
        }
        listener.start(queue: queue)
    }

    public nonisolated func stop() { listener.cancel() }

    // MARK: A connection

    private static func serve(_ connection: NWConnection, queue: DispatchQueue, secure: Bool, uploads: URL, uploadPath: String,
                              handle: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) async {
        connection.start(queue: queue)
        defer { connection.cancel() }
        var buffer = Data()
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            guard buffer.count < 64 << 10, let chunk = await receive(connection) else { return }
            buffer.append(chunk)
            headEnd = buffer.range(of: Data("\r\n\r\n".utf8))
        }
        guard let headEnd, let head = HTTPRequest.head(String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)) else {
            await send(connection, response: .error("Not a request this server reads", status: 400))
            return
        }
        var request = HTTPRequest(method: head.method, path: head.path, query: head.query, headers: head.headers,
                                  local: isLoopback(connection.endpoint), secure: secure)
        let length = Int64(head.headers["content-length"] ?? "") ?? 0
        let start = buffer[headEnd.upperBound...]
        if length > 0 {
            if head.path == uploadPath {
                guard length <= uploadLimit, let file = await receiveFile(connection, length: length, start: Data(start), into: uploads) else {
                    await send(connection, response: .error("The upload did not arrive whole", status: 400))
                    return
                }
                request.bodyFile = file
            } else {
                guard length <= memoryLimit else {
                    await send(connection, response: .error("Too large", status: 413))
                    return
                }
                var body = Data(start)
                while Int64(body.count) < length {
                    guard let chunk = await receive(connection) else { return }
                    body.append(chunk)
                }
                request.body = body.prefix(Int(length))
            }
        }
        let response = await handle(request)
        if let file = request.bodyFile { try? FileManager.default.removeItem(at: file) }
        await send(connection, response: response, head: head.method == "HEAD")
    }

    /// The upload's bytes, written to a file of their own as they come.
    private static func receiveFile(_ connection: NWConnection, length: Int64, start: Data, into folder: URL) async -> URL? {
        let file = folder.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { return nil }
        defer { try? handle.close() }
        var written: Int64 = 0
        var chunk: Data? = start
        while written < length {
            guard let data = chunk else {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            let part = data.prefix(Int(min(Int64(data.count), length - written)))
            do { try handle.write(contentsOf: part) } catch { return nil }
            written += Int64(part.count)
            if written < length { chunk = await receive(connection) }
        }
        return file
    }

    private static func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { data, _, _, error in
                if let data, !data.isEmpty, error == nil {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @discardableResult
    private static func send(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
    }

    private static func send(_ connection: NWConnection, response: HTTPResponse, head: Bool = false) async {
        var headers = response.headers
        switch response.body {
        case .data(let data): headers["Content-Length"] = String(data.count)
        case .file(_, let size): headers["Content-Length"] = String(size)
        }
        headers["Connection"] = "close"
        var text = "HTTP/1.1 \(response.status) \(HTTPResponse.reason(response.status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        guard await send(connection, Data(text.utf8)) else { return }
        if !head, !(await send(connection, body: response.body)) { return }
        await finish(connection)
    }

    private static func send(_ connection: NWConnection, body: HTTPResponse.Body) async -> Bool {
        switch body {
        case .data(let data):
            if data.isEmpty { return true }
            return await send(connection, data)
        case .file(let url, _):
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            while let chunk = try? handle.read(upToCount: 256 << 10), !chunk.isEmpty {
                guard await send(connection, chunk) else { return false }
            }
            return true
        }
    }

    /// The answer's end: the write side closed behind everything written,
    /// then the client's own close waited for (half a minute at most).
    /// A write is done when the stack has taken it, not when it has gone;
    /// letting the connection go then cut a slow path's answer short (the
    /// tailnet's, at 128 KB).
    private static func finish(_ connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in continuation.resume() })
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { while await receive(connection) != nil {} }
            group.addTask { try? await Task.sleep(for: .seconds(30)) }
            await group.next()
            group.cancelAll()
            // Ends the wait on the client, if it was the clock that ran out.
            connection.cancel()
        }
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address == .loopback
        case .ipv6(let address): return address == .loopback || address.asIPv4 == .loopback
        default: return false
        }
    }
}
