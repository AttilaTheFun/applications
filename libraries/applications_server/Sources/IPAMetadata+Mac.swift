import ApplicationsProtocol
import Foundation
import PipelineServer

extension IPAMetadata {
    /// A Mac app's .zip: `<Name>.app/Contents/Info.plist`, the .icns it
    /// names (as a PNG, by the system's sips), and the executable in
    /// Contents/MacOS.
    static func readMac(_ zip: URL, entries: [String], plistEntry: String) throws -> IPAMetadata {
        let contents = String(plistEntry.dropLast("Info.plist".count))
        let plistData = try ProcessRunner.run("/usr/bin/unzip", ["-p", zip.path, plistEntry])
        guard let info = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else { throw ReadError("Its Info.plist names no bundle id") }
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleID
        var metadata = IPAMetadata(bundleID: bundleID, name: name, version: (info["CFBundleShortVersionString"] as? String) ?? "",
                                   buildNumber: (info["CFBundleVersion"] as? String) ?? "", icon: nil)
        metadata.platform = "macos"
        metadata.urlSchemes = urlSchemes(in: info)
        metadata.buildVariant = info["BuildVariant"] as? String
        if let file = info["CFBundleIconFile"] as? String {
            let entry = contents + "Resources/" + (file.hasSuffix(".icns") ? file : file + ".icns")
            if entries.contains(entry), let icns = try? ProcessRunner.run("/usr/bin/unzip", ["-p", zip.path, entry]) {
                metadata.icon = png(fromICNS: icns)
            }
        }
        if let executable = info["CFBundleExecutable"] as? String, entries.contains(contents + "MacOS/" + executable),
           let binary = try? ProcessRunner.run("/usr/bin/unzip", ["-p", zip.path, contents + "MacOS/" + executable]) {
            metadata.executableUUID = MachOUUID.uuid(in: binary)
        }
        return metadata
    }

    /// An .icns as a 512-point PNG, or nil.
    static func png(fromICNS icns: Data) -> Data? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("icon-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("icon.icns"), output = folder.appendingPathComponent("icon.png")
        guard (try? icns.write(to: input)) != nil,
              (try? ProcessRunner.run("/usr/bin/sips", ["-s", "format", "png", "-Z", "512", input.path, "--out", output.path])) != nil
        else { return nil }
        return try? Data(contentsOf: output)
    }

    /// A Mac app's disk image as the .zip the server keeps: mounted read
    /// only, its one .app zipped, unmounted.
    static func zip(fromDiskImage image: URL, to zip: URL) throws {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("dmg-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount) }
        try ProcessRunner.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path])
        defer { _ = try? ProcessRunner.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: mount.path)) ?? []).filter { $0.hasSuffix(".app") }
        guard apps.count == 1 else { throw ReadError("A disk image with one .app in it, not \(apps.count)") }
        try ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", mount.appendingPathComponent(apps[0]).path, zip.path])
    }

    /// Whether a file is a zip archive (an .ipa is one).
    static func isZip(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }
}
