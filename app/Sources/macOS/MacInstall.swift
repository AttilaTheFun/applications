import AppKit
import ApplicationsProtocol
import Security

/// Puts a downloaded build in place: unzipped, checked to be the app it says
/// and signed by this app's own team, the running copy asked to quit, the
/// installed one replaced (it goes to the Trash), and opened again if it was
/// running. Applications itself is replaced by a helper once it has quit.
enum MacInstall {
    struct Failure: Error, LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// `earlier`: the app's bundle ids from before one bundle id an app,
    /// whose copy under its name the build replaces (InstalledApps).
    static func install(zip: URL, build: Build, earlier: Set<String> = []) async throws {
        let folder = zip.deletingLastPathComponent().appendingPathComponent("unzipped", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".app") }
        guard apps.count == 1 else { throw Failure("The build has \(apps.count) apps in it, not one.") }
        let new = folder.appendingPathComponent(apps[0])
        guard Bundle(url: new)?.bundleIdentifier == build.bundleID else { throw Failure("The build is not \(build.name).") }
        try checkSignature(of: new)

        let destination = InstalledApps.destination(bundleID: build.bundleID, name: build.name, earlier: earlier)
        // An earlier bundle id's copy where the build goes: quit, and to the Trash.
        if let there = Bundle(url: destination)?.bundleIdentifier, there != build.bundleID {
            try await quit(bundleID: there, name: build.name)
            try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
        }
        if build.bundleID == Bundle.main.bundleIdentifier {
            try replaceSelf(at: destination, old: Bundle.main.bundleURL, with: new)
            return
        }
        let current = InstalledApps.current(bundleID: build.bundleID, name: build.name)
        let running = try await quit(bundleID: build.bundleID, name: build.name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
        }
        // Its copy under another name (`<name> (<id>).app`): one copy, under its own.
        if let current, current.standardizedFileURL != destination.standardizedFileURL, FileManager.default.fileExists(atPath: current.path) {
            try FileManager.default.trashItem(at: current, resultingItemURL: nil)
        }
        try FileManager.default.moveItem(at: new, to: destination)
        if !running.isEmpty {
            _ = try? await NSWorkspace.shared.openApplication(at: destination, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Quits the app if it is running and moves it to the Trash.
    static func uninstall(bundleID: String, name: String) async throws {
        guard let location = InstalledApps.current(bundleID: bundleID, name: name),
              FileManager.default.fileExists(atPath: location.path) else { return }
        try await quit(bundleID: bundleID, name: name)
        try FileManager.default.trashItem(at: location, resultingItemURL: nil)
    }

    /// Asks the app to quit and waits for it; throws when it will not.
    /// The apps that were running, to open again after.
    @discardableResult
    static func quit(bundleID: String, name: String) async throws -> [NSRunningApplication] {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        for app in running { app.terminate() }
        for _ in 0..<60 where running.contains(where: { !$0.isTerminated }) { try await Task.sleep(nanoseconds: 250_000_000) }
        guard running.allSatisfy(\.isTerminated) else { throw Failure("\(name) did not quit. Quit it, then try again.") }
        return running
    }

    /// The app must pass the system's check of its signature, and be
    /// signed by the team that signed Applications.
    static func checkSignature(of app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure("The build's signature cannot be read.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw Failure("The build's signature is not valid.") }
        guard let team = teamID(of: code), team == ownTeam else { throw Failure("The build is not signed by this Mac's team.") }
    }

    private static var ownTeam: String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return teamID(of: code)
    }

    private static func teamID(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Applications cannot replace itself while it runs: a shell waits for it
    /// to quit, puts the new one at `destination`, takes away the copy it ran
    /// from (`old`) if that was elsewhere (under its id's name), and opens
    /// the new one.
    private static func replaceSelf(at destination: URL, old: URL, with new: URL) throws {
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".Applications-new-\(UUID().uuidString).app")
        try FileManager.default.moveItem(at: new, to: staged)
        let pid = ProcessInfo.processInfo.processIdentifier
        let removeOld = old.standardizedFileURL == destination.standardizedFileURL ? "" : "rm -rf \"\(old.path)\" && "
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        \(removeOld)rm -rf "\(destination.path)" && mv "\(staged.path)" "\(destination.path)" && open "\(destination.path)"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        try helper.run()
        Task { @MainActor in NSApp.terminate(nil) }
    }

    private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("\(URL(fileURLWithPath: path).lastPathComponent) failed (\(process.terminationStatus)).") }
    }
}
