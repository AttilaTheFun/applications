import Foundation

/// A small .ipa made for a test: Payload/<name>.app with an Info.plist,
/// an icon and an executable (a copy of /usr/bin/true, a real Mach-O),
/// zipped with the system's zip.
enum TestIPA {
    static func make(in folder: URL, bundleID: String = "com.example.Visor", name: String = "Visor", version: String = "0.23",
                     build: String = "23", appleDouble: Bool = false, applicationIdentifier: String? = nil,
                     stamped scheme: String? = nil, variant: String? = nil) throws -> URL {
        let work = folder.appendingPathComponent(UUID().uuidString)
        let app = work.appendingPathComponent("Payload/\(name).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        // The app's own scheme, and the build's when CI stamped one in.
        var types: [[String: Any]] = [["CFBundleURLSchemes": ["testapp"]]]
        if let scheme { types.append(["CFBundleURLName": "applications-build", "CFBundleURLSchemes": [scheme]]) }
        var info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleDisplayName": name, "CFBundleShortVersionString": version,
                                   "CFBundleVersion": build, "CFBundleExecutable": name,
                                   "CFBundleURLTypes": types,
                                   "CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]]]
        if let variant { info["BuildVariant"] = variant }
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try Data("icon-2x".utf8).write(to: app.appendingPathComponent("AppIcon60x60@2x.png"))
        try Data("icon-3x".utf8).write(to: app.appendingPathComponent("AppIcon60x60@3x.png"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent(name))
        try TestMacApp.signAdHoc(app, entitlements: applicationIdentifier.map { ["application-identifier": $0] })
        if appleDouble { try Data("attributes".utf8).write(to: app.appendingPathComponent("._Info.plist")) }
        let ipa = folder.appendingPathComponent(UUID().uuidString + ".ipa")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-qr", ipa.path, "Payload"]
        zip.currentDirectoryURL = work
        try zip.run()
        zip.waitUntilExit()
        return ipa
    }

    static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("applications-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
