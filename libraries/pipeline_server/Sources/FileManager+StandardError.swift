import Foundation

public extension FileManager {
    /// A line for the server's log (standard error, which launchd keeps).
    func standardError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
