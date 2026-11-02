// swift-tools-version: 5.9

// The SwiftPM dependencies consumed through rules_swift_package_manager:
// AgentUI (MarkdownViews: a build's release notes as written) and swift_sql
// (SQLite, which no target uses yet). rspm reads Package.resolved
// for the pinned graph and generates one `@swiftpkg_<name>` repo per
// package.
import PackageDescription

let package = Package(
    name: "pipeline_swift_packages",
    platforms: [.iOS("18.0"), .macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/AttilaTheFun/swift_sql.git", exact: "0.35.0"),
        // v0.33's commit (its tag is not a full version SwiftPM reads).
        .package(url: "https://github.com/AttilaTheFun/agent_ui.git", exact: "0.38.0"),
    ]
)
