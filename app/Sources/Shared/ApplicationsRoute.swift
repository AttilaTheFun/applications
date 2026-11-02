/// Where Applications has gone past an app's builds: one build (by id), or
/// one of the app's versions (the app's name, the version).
enum ApplicationsRoute: Hashable {
    case build(String)
    case version(String, String)
}
