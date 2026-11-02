import Foundation

/// A small Mac app made for a test: <Name>.app with an Info.plist, an
/// icon (the system's generic application icon) and an executable (a copy
/// of /usr/bin/true), as a .zip or a disk image.
enum TestMacApp {
    static func make(in folder: URL, bundleID: String = "com.example.VisorMac", name: String = "Visor", version: String = "0.24",
                     build: String = "24", diskImage: Bool = false, signed: Bool = true) throws -> URL {
        let work = folder.appendingPathComponent(UUID().uuidString)
        let app = work.appendingPathComponent("\(name).app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleShortVersionString": version,
                                   "CFBundleVersion": build, "CFBundleExecutable": name, "CFBundleIconFile": "AppIcon"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"),
                                         to: app.appendingPathComponent("Resources/AppIcon.icns"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("MacOS/\(name)"))
        let bundle = work.appendingPathComponent("\(name).app")
        if signed { try signAdHoc(bundle) }
        let output = folder.appendingPathComponent(UUID().uuidString + (diskImage ? ".dmg" : ".zip"))
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: diskImage ? "/usr/bin/hdiutil" : "/usr/bin/ditto")
        tool.arguments = diskImage ? ["create", "-quiet", "-srcfolder", bundle.path, "-format", "UDZO", output.path]
                                   : ["-c", "-k", "--keepParent", bundle.path, output.path]
        try tool.run()
        tool.waitUntilExit()
        return output
    }

    /// Signs a bundle ad hoc, as a test's build needs to pass the check.
    static func signAdHoc(_ bundle: URL, entitlements: [String: Any]? = nil) throws {
        var arguments = ["--force", "--sign", "-"]
        if let entitlements {
            let file = bundle.deletingLastPathComponent().appendingPathComponent("entitlements.plist")
            try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: file)
            arguments += ["--entitlements", file.path]
        }
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = arguments + [bundle.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
    }
}
