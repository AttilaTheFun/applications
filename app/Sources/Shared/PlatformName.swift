/// A platform's name, as people say it.
enum PlatformName {
    static func title(_ platform: String) -> String {
        switch platform {
        case "ios": "iPhone & iPad"
        case "macos": "Mac"
        case "android": "Android"
        default: platform
        }
    }
}
