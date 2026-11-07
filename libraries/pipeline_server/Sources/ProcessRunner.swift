import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// A command run to its end: what it printed, and how it ended.
public enum ProcessRunner {
    public struct Failure: Error, CustomStringConvertible {
        public let command: String
        public let status: Int32
        public let output: String
        public var description: String { "\(command) exited \(status): \(output)" }
    }

    /// Runs `path` with `arguments`; its standard output, or a Failure
    /// (with its standard error) when it does not exit 0. Given a
    /// `timeout`, one still running then is stopped (terminated, and killed
    /// five seconds later if it is still there) and fails, saying so.
    @discardableResult
    public static func run(_ path: String, _ arguments: [String], in folder: URL? = nil, timeout: TimeInterval? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = folder }
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let timedOut = TimedOut()
        if let timeout {
            // By its pid alone (a Process isn't Sendable); the run marks it
            // ended first, so a pid used again by then is left alone.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !timedOut.ended else { return }
                timedOut.set()
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if !timedOut.ended { kill(pid, SIGKILL) }
                }
            }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timedOut.end()
        if timedOut.value, let timeout {
            throw Failure(command: ([path] + arguments).joined(separator: " "), status: process.terminationStatus,
                          output: "stopped after \(Int(timeout)) s, still running")
        }
        guard process.terminationStatus == 0 else {
            throw Failure(command: ([path] + arguments).joined(separator: " "), status: process.terminationStatus,
                          output: String(decoding: failure, as: UTF8.self))
        }
        return data
    }

    /// Whether a run was stopped for its time, and whether it has ended,
    /// shared with the timer's queue.
    private final class TimedOut: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var over = false
        func set() { lock.withLock { stopped = true } }
        func end() { lock.withLock { over = true } }
        var value: Bool { lock.withLock { stopped } }
        var ended: Bool { lock.withLock { over } }
    }
}
