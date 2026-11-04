import Foundation

/// A server launchd keeps running for this user, at login and whenever it
/// exits: a LaunchAgent in ~/Library/LaunchAgents that runs its binary
/// with `serve`, its output in a log. Installing copies the running binary
/// to where the agent runs it from first, so the service does not run out
/// of a checkout's bazel-out, which the next build there replaces;
/// installing again replaces it and starts the new build.
public struct LaunchAgent: Sendable {
    /// launchd's label (com.LoganShire.ApplicationsServer).
    public let label: String
    /// Where the agent runs the binary from, copied there by `install`.
    public let binary: URL
    /// What it is run with.
    public let arguments: [String]
    /// Its standard output and standard error, both.
    public let log: URL
    /// What its environment has beyond launchd's own.
    public let environment: [String: String]
    /// The agent's definition: ~/Library/LaunchAgents/<label>.plist.
    public let plist: URL

    public init(label: String, binary: URL, arguments: [String] = ["serve"], log: URL, environment: [String: String] = [:],
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.label = label
        self.binary = binary
        self.arguments = arguments
        self.log = log
        self.environment = environment
        plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private var domain: String { "gui/\(getuid())" }
    private var service: String { "\(domain)/\(label)" }

    /// What launchd is given: the binary with its arguments, started at
    /// login and again whenever it exits (no sooner than ten seconds
    /// after the last start, so a server that cannot listen does not spin).
    public var definition: [String: Any] {
        var agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary.path] + arguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
        ]
        if !environment.isEmpty { agent["EnvironmentVariables"] = environment }
        return agent
    }

    /// The definition as the plist written.
    public func definitionData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
    }

    /// `running` copied to the binary's place (unless it is the one there),
    /// the agent written and loaded, in place of one loaded before.
    @discardableResult
    public func install(running: URL? = Bundle.main.executableURL) throws -> Standing {
        guard let running = running?.resolvingSymlinksInPath() else {
            throw ProcessRunner.Failure(command: "install", status: 1, output: "Which binary is running is not known.")
        }
        let files = FileManager.default
        for folder in [binary, plist, log].map({ $0.deletingLastPathComponent() }) {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if running != binary.resolvingSymlinksInPath() {
            // Copied beside it and renamed over it: the running service
            // keeps the build it started with until launchd starts this one.
            let copy = binary.deletingLastPathComponent().appendingPathComponent(".\(binary.lastPathComponent)-\(UUID().uuidString)")
            try files.copyItem(at: running, to: copy)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
            guard rename(copy.path, binary.path) == 0 else {
                try? files.removeItem(at: copy)
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: binary.path])
            }
        }
        unload()
        try definitionData().write(to: plist, options: .atomic)
        // launchd can still be letting the one before go after bootout
        // says it has, and refuses the new one meanwhile ("Bootstrap
        // failed: 5: Input/output error"): tried again, waiting longer each
        // time, for up to half a minute.
        var attempt = 0
        while true {
            do {
                try ProcessRunner.run("/bin/launchctl", ["bootstrap", domain, plist.path])
                break
            } catch {
                guard attempt < Self.bootstrapWaits.count else { throw error }
                Thread.sleep(forTimeInterval: Self.bootstrapWaits[attempt])
                attempt += 1
            }
        }
        return standing()
    }

    /// How long `install` waits before each bootstrap tried again.
    static let bootstrapWaits: [TimeInterval] = [1, 2, 4, 8, 15]

    /// The agent stopped and let go, its plist removed (the binary stays,
    /// for the command's other uses): whether there was one.
    @discardableResult
    public func remove() -> Bool {
        let had = FileManager.default.fileExists(atPath: plist.path) || standing().loaded
        unload()
        try? FileManager.default.removeItem(at: plist)
        return had
    }

    /// The service stopped, waiting (ten seconds at most) until launchd
    /// has let it go.
    private func unload() {
        guard standing().loaded else { return }
        _ = try? ProcessRunner.run("/bin/launchctl", ["bootout", service])
        var waited = 0
        while waited < 40, standing().loaded {
            Thread.sleep(forTimeInterval: 0.25)
            waited += 1
        }
    }

    /// The server stopped and started again (launchd starts the binary
    /// there now).
    @discardableResult
    public func restart() throws -> Standing {
        try ProcessRunner.run("/bin/launchctl", ["kickstart", "-k", service])
        return standing()
    }

    /// Whether launchd has it, and its state and pid, as `launchctl print`
    /// says them.
    public struct Standing: Sendable, Equatable, CustomStringConvertible {
        public var loaded: Bool
        /// "running", "waiting" (between starts) and so on.
        public var state: String?
        public var pid: Int?

        public var description: String {
            guard loaded else { return "not loaded" }
            return [state, pid.map { "pid \($0)" }].compactMap { $0 }.joined(separator: ", ")
        }
    }

    public func standing() -> Standing {
        guard let printed = try? ProcessRunner.run("/bin/launchctl", ["print", service]) else {
            return Standing(loaded: false)
        }
        let lines = String(decoding: printed, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func value(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key + " = ") }.map { String($0.dropFirst(key.count + 3)) }
        }
        return Standing(loaded: true, state: value("state"), pid: value("pid").flatMap { Int($0) })
    }
}
