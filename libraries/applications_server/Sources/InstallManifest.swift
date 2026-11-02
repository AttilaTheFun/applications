import ApplicationsProtocol
import Foundation

/// The manifest iOS reads for an over-the-air install
/// (itms-services): where the .ipa is, and which app and version it is.
public enum InstallManifest {
    public static func plist(ipaURL: String, bundleID: String, version: String, title: String) -> Data {
        let manifest: [String: Any] = [
            "items": [[
                "assets": [["kind": "software-package", "url": ipaURL]],
                "metadata": ["bundle-identifier": bundleID, "bundle-version": version, "kind": "software", "title": title],
            ]],
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)) ?? Data()
    }

    /// The link that starts the install, for a manifest at `manifestURL`.
    public static func installLink(manifestURL: String) -> String { InstallLink.make(manifestURL: manifestURL) }
}
