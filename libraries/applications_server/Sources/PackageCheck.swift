import Foundation
import PipelineServer

/// What is checked of a package before it is published, so a device never
/// gets a build it will refuse: an .ipa loses the AppleDouble files ("._…",
/// __MACOSX/) an archiver may have put in it from macOS's extended
/// attributes — iOS counts them as files added to the signed app and will
/// not install it — the app in it must have a signature that verifies,
/// as the device checks it, and an iPhone app must be signed as itself.
/// An .apk must carry a signing block of v2 or later (APKSignature).
enum PackageCheck {
    /// Removes the AppleDouble entries from an .ipa, if it has any.
    static func strip(ipa: URL) throws {
        let entries = String(decoding: try ProcessRunner.run("/usr/bin/unzip", ["-Z1", ipa.path]), as: UTF8.self)
        let doubles = entries.split(separator: "\n").map(String.init).filter(isAppleDouble)
        guard !doubles.isEmpty else { return }
        try ProcessRunner.run("/usr/bin/zip", ["-q", "-d", ipa.path] + doubles)
    }

    static func isAppleDouble(_ entry: String) -> Bool {
        entry.hasPrefix("__MACOSX/") || entry.split(separator: "/").last?.hasPrefix("._") == true
    }

    /// Unpacks the package as its platform does (the Mac's ditto keeps a
    /// .zip's AppleDouble entries as attributes) and verifies the app's
    /// signature; throws what codesign says when it does not.
    static func verify(package: URL, platform: String) throws {
        if platform == "android" {
            _ = try APKSignature.signer(of: package)
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("check-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", package.path, folder.path])
        let root = platform == "macos" ? folder : folder.appendingPathComponent("Payload")
        guard let app = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).first(where: { $0.hasSuffix(".app") }) else {
            throw Refusal("No app in it")
        }
        do {
            try ProcessRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", root.appendingPathComponent(app).path])
        } catch let failure as ProcessRunner.Failure {
            throw Refusal("Its signature does not verify, so the device would refuse it: "
                          + failure.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if platform == "ios" { try checkIdentifier(of: root.appendingPathComponent(app)) }
    }

    /// An iPhone app's signed application-identifier must be the team's
    /// prefix and its own bundle id. Entitlements copied whole from a
    /// wildcard profile ("<team>.*") still verify, but iOS will not install
    /// the app: the device keeps the build it had, and Applications offers
    /// the new one again and again. An app signed with no entitlements (ad
    /// hoc, a test's) has nothing to check.
    static func checkIdentifier(of app: URL) throws {
        let signed = try ProcessRunner.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path])
        guard !signed.isEmpty,
              let entitlements = try? PropertyListSerialization.propertyList(from: signed, format: nil) as? [String: Any],
              let identifier = entitlements["application-identifier"] as? String,
              let info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")),
                                                                     format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String,
              !identifier.hasSuffix("." + bundleID) else { return }
        // Without the team's prefix: the refusal is printed where it is published.
        let signedAs = identifier.split(separator: ".", maxSplits: 1).last.map(String.init) ?? identifier
        throw Refusal("It is signed as \"<team>.\(signedAs)\", not as its bundle id \(bundleID), so iOS would not install it: "
                      + "sign it with application-identifier <team>.\(bundleID) (a wildcard profile's entitlements, made concrete)")
    }

    struct Refusal: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
