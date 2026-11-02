import Foundation

/// The link that starts an over-the-air install: iOS reads
/// the manifest at `manifestURL` (HTTPS it trusts) and fetches the app.
public enum InstallLink {
    public static func make(manifestURL: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?&=")
        return "itms-services://?action=download-manifest&url=" + (manifestURL.addingPercentEncoding(withAllowedCharacters: allowed) ?? manifestURL)
    }
}
