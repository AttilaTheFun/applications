import Foundation

/// A command run to its end: what it printed, and how it ended.
public enum ProcessRunner {
    public struct Failure: Error, CustomStringConvertible {
        public let command: String
        public let status: Int32
        public let output: String
        public var description: String { "\(command) exited \(status): \(output)" }
    }

    /// Runs `path` with `arguments`; its standard output, or a Failure
    /// (with its standard error) when it does not exit 0.
    @discardableResult
    public static func run(_ path: String, _ arguments: [String], in folder: URL? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = folder }
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(command: ([path] + arguments).joined(separator: " "), status: process.terminationStatus,
                          output: String(decoding: failure, as: UTF8.self))
        }
        return data
    }
}
