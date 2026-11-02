import ApplicationsProtocol
import Foundation
import PipelineServer

/// What a published package says of itself — an iPhone app's .ipa, a
/// Mac app's .zip (`<Name>.app` at its top, as rules_apple and `ditto -c
/// -k --keepParent` make it), or an Android app's .apk: its app's
/// Info.plist (or manifest), its icon, its executable's UUID or its
/// signer, and which platform it is for.
public struct IPAMetadata: Sendable, Equatable {
    public var bundleID: String
    public var name: String
    public var version: String
    public var buildNumber: String
    public var icon: Data?
    /// The executable's UUID (`MachOUUID`), which tells builds with the
    /// same numbers apart.
    public var executableUUID: String?
    /// "ios" for an .ipa, "macos" for a Mac app's .zip, "android" for an
    /// .apk.
    public var platform = "ios"
    /// The URL schemes its Info.plist declares.
    public var urlSchemes: [String] = []
    /// Its Info.plist's `BuildVariant` (Alpha, Beta or Production), where it
    /// has one: checked against how it's published (CIPolicy.checkVariant).
    public var buildVariant: String?
    /// An .apk's signing certificate's SHA-256, in hex.
    public var signer: String?

    static func urlSchemes(in info: [String: Any]) -> [String] {
        ((info["CFBundleURLTypes"] as? [[String: Any]]) ?? []).flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
    }

    /// Reads an .ipa with the system's unzip: the one app under Payload/,
    /// its Info.plist, and the largest of the icons it names.
    public static func read(_ ipa: URL) throws -> IPAMetadata {
        let listing = String(decoding: try ProcessRunner.run("/usr/bin/unzip", ["-Z1", ipa.path]), as: UTF8.self)
        let entries = listing.split(separator: "\n").map(String.init)
        if entries.contains("AndroidManifest.xml") { return try readAndroid(ipa, entries: entries) }
        if let macPlist = entries.first(where: { entry in
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 3 && parts[0].hasSuffix(".app") && parts[1] == "Contents" && parts[2] == "Info.plist"
        }) {
            return try readMac(ipa, entries: entries, plistEntry: macPlist)
        }
        guard let plistEntry = entries.first(where: { entry in
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }) else { throw ReadError("No app in it (Payload/<name>.app/Info.plist)") }
        let appFolder = String(plistEntry.dropLast("Info.plist".count))
        let plistData = try ProcessRunner.run("/usr/bin/unzip", ["-p", ipa.path, plistEntry])
        guard let info = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else { throw ReadError("Its Info.plist names no bundle id") }
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleID
        let version = (info["CFBundleShortVersionString"] as? String) ?? ""
        let buildNumber = (info["CFBundleVersion"] as? String) ?? ""
        var icon: Data?
        let candidates = iconEntries(info: info, appFolder: appFolder, entries: entries)
        if let best = candidates.first { icon = try? ProcessRunner.run("/usr/bin/unzip", ["-p", ipa.path, best]) }
        var executableUUID: String?
        if let executable = info["CFBundleExecutable"] as? String, entries.contains(appFolder + executable),
           let binary = try? ProcessRunner.run("/usr/bin/unzip", ["-p", ipa.path, appFolder + executable]) {
            executableUUID = MachOUUID.uuid(in: binary)
        }
        var metadata = IPAMetadata(bundleID: bundleID, name: name, version: version, buildNumber: buildNumber, icon: icon,
                                   executableUUID: executableUUID)
        metadata.urlSchemes = urlSchemes(in: info)
        metadata.buildVariant = info["BuildVariant"] as? String
        return metadata
    }

    /// The app's icon files in the archive, largest first: those its
    /// Info.plist names (CFBundleIcons), else any AppIcon*.png.
    static func iconEntries(info: [String: Any], appFolder: String, entries: [String]) -> [String] {
        let primary = ((info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any])
        var names = (primary?["CFBundleIconFiles"] as? [String]) ?? []
        if let name = primary?["CFBundleIconName"] as? String { names.append(name) }
        if names.isEmpty { names = ["AppIcon"] }
        let pngs = entries.filter { entry in
            entry.hasPrefix(appFolder) && entry.hasSuffix(".png") && !entry.dropFirst(appFolder.count).contains("/")
                && names.contains { entry.dropFirst(appFolder.count).hasPrefix($0) }
        }
        func scale(_ entry: String) -> Int { entry.contains("@3x") ? 3 : entry.contains("@2x") ? 2 : 1 }
        func points(_ entry: String) -> Int {
            let digits = entry.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return digits.first ?? 0
        }
        return pngs.sorted { (points($0) * scale($0), $0) > (points($1) * scale($1), $1) }
    }

    struct ReadError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
