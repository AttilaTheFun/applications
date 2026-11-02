import Foundation
import SystemConfiguration

/// The Mac's Bonjour name ("example-mac.local"), what the LAN knows it
/// by. (ProcessInfo's host name is what reverse DNS says, which can be the
/// provider's name for the Mac's IPv6 address.)
public enum HostName {
    public static var local: String {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0.lowercased() + ".local" }
            ?? ProcessInfo.processInfo.hostName.lowercased()
    }
}
