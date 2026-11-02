// swift-tools-version: 6.0

// ApplicationUpdates for the apps Applications distributes, as a Swift
// package: another repository depends on this one by version (its tags)
// through rules_swift_package_manager, as on its other Swift packages,
// and imports ApplicationUpdates (docs/Updates.md). This repository builds
// the same sources with Bazel (libraries/application_updates); nothing
// else here is part of the package.
import PackageDescription

let package = Package(
    name: "applications",
    // swift_sql's own floor: an app of any of the apps' minimums takes it.
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ApplicationUpdates", targets: ["ApplicationUpdates"]),
    ],
    dependencies: [
        // A range, not one version: the apps pin swift_sql themselves, and
        // their pin is the one taken.
        .package(url: "https://github.com/AttilaTheFun/swift_sql.git", from: "0.35.0"),
    ],
    targets: [
        .target(
            name: "ApplicationUpdates",
            dependencies: [.product(name: "SwiftSQL", package: "swift_sql")],
            path: "libraries/application_updates/Sources"),
        .testTarget(
            name: "ApplicationUpdatesTests",
            dependencies: ["ApplicationUpdates", .product(name: "SwiftSQL", package: "swift_sql")],
            path: "libraries/application_updates/tests",
            exclude: ["BUILD.bazel"]),
    ],
    swiftLanguageModes: [.v6]
)
