/// CI asking for the version its build of an app takes, before it builds
/// it (`POST /api/next-version`; `applications-server next-version` on the
/// server's Mac): the next of the app's line, MAJOR.MINOR.BUILD. Asked
/// again for the same app, line and commit, the answer is the same.
public struct NextVersionRequest: Codable, Sendable, Equatable {
    /// The app, as the server counts its builds ("Applications" for
    /// Applications β's too).
    public var app: String
    /// MAJOR.MINOR, as the repository commits it (MAJOR.MINOR.0).
    public var line: String
    /// The commit built, when asked with the password: its sha, or at
    /// least its first seven characters. A CI job's is its token's `sha`,
    /// and this is not read.
    public var commit: String?

    public init(app: String, line: String, commit: String? = nil) {
        self.app = app
        self.line = line
        self.commit = commit
    }

    /// Whether the line is MAJOR.MINOR, each a number.
    public var isLine: Bool {
        let parts = line.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
}
