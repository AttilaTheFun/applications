import ApplicationsProtocol
import Foundation
import PipelineServer

extension IPAMetadata {
    /// An Android app's .apk: its compiled AndroidManifest.xml (the
    /// package, versionName and versionCode, the application's label and
    /// icon), the label and the icon's files found in resources.arsc, and
    /// the certificate it is signed with.
    static func readAndroid(_ apk: URL, entries: [String]) throws -> IPAMetadata {
        let manifestData = try ProcessRunner.run("/usr/bin/unzip", ["-p", apk.path, "AndroidManifest.xml"])
        guard let manifest = AndroidBinaryXML(manifestData), let root = manifest.elements.first(where: { $0.name == "manifest" }),
              case .string(let package)? = root.attribute("package"), !package.isEmpty else {
            throw ReadError("Its AndroidManifest.xml names no package")
        }
        let resources = entries.contains("resources.arsc")
            ? (try? ProcessRunner.run("/usr/bin/unzip", ["-p", apk.path, "resources.arsc"])).flatMap(AndroidResources.init) : nil
        func text(_ value: AndroidBinaryXML.Value?) -> String? {
            switch value {
            case .string(let text): return text
            case .reference(let id): return resources?.string(id)
            default: return nil
            }
        }
        let application = manifest.elements.first { $0.name == "application" }
        var buildNumber = ""
        if case .integer(let code)? = root.attribute("versionCode", id: AndroidBinaryXML.AttributeID.versionCode) {
            buildNumber = String(code)
        }
        var metadata = IPAMetadata(bundleID: package,
                                   name: text(application?.attribute("label", id: AndroidBinaryXML.AttributeID.label)) ?? package,
                                   version: text(root.attribute("versionName", id: AndroidBinaryXML.AttributeID.versionName)) ?? "",
                                   buildNumber: buildNumber, icon: nil)
        metadata.platform = "android"
        metadata.signer = try? APKSignature.signer(of: apk)
        let icon = application?.attribute("icon", id: AndroidBinaryXML.AttributeID.icon)
            ?? application?.attribute("roundIcon", id: AndroidBinaryXML.AttributeID.roundIcon)
        if case .reference(let id)? = icon, let resources, let entry = iconEntry(resources.files(id), entries: entries) {
            let image = try? ProcessRunner.run("/usr/bin/unzip", ["-p", apk.path, entry])
            metadata.icon = entry.hasSuffix(".png") ? image : image.flatMap(png(fromWebP:))
        }
        return metadata
    }

    /// The icon's best picture: a PNG (or WebP) of the highest density it
    /// has. An adaptive icon (XML, for any density) is drawn by the
    /// launcher, so the PNGs of the same name stand for it, when there are.
    static func iconEntry(_ files: [(path: String, density: UInt16)], entries: [String]) -> String? {
        func rank(_ density: UInt16) -> Int { density == 0 ? 160 : density >= 0xFFFE ? 0 : Int(density) }
        func isPicture(_ path: String) -> Bool { path.hasSuffix(".png") || path.hasSuffix(".webp") }
        var pictures = files.filter { isPicture($0.path) && entries.contains($0.path) }
        if pictures.isEmpty {
            let names = Set(files.map { ($0.path as NSString).lastPathComponent.split(separator: ".").first.map(String.init) ?? "" })
            pictures = entries.filter { entry in
                let parts = entry.split(separator: "/")
                return parts.count == 3 && parts[0] == "res" && isPicture(entry)
                    && names.contains(parts[2].split(separator: ".").first.map(String.init) ?? "")
            }.map { ($0, density(ofFolder: String($0.split(separator: "/")[1]))) }
        }
        return pictures.max { (rank($0.density), $0.path.hasSuffix(".png") ? 1 : 0) < (rank($1.density), $1.path.hasSuffix(".png") ? 1 : 0) }?.path
    }

    /// The density a resource folder's qualifiers name ("mipmap-xxxhdpi-v4").
    static func density(ofFolder folder: String) -> UInt16 {
        let qualifiers: [(String, UInt16)] = [("xxxhdpi", 640), ("xxhdpi", 480), ("xhdpi", 320), ("hdpi", 240), ("mdpi", 160), ("ldpi", 120)]
        let parts = folder.split(separator: "-").map(String.init)
        return qualifiers.first { parts.contains($0.0) }?.1 ?? 0
    }

    /// A WebP picture as a PNG (by the system's sips), or nil.
    static func png(fromWebP webp: Data) -> Data? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("icon-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("icon.webp"), output = folder.appendingPathComponent("icon.png")
        guard (try? webp.write(to: input)) != nil,
              (try? ProcessRunner.run("/usr/bin/sips", ["-s", "format", "png", input.path, "--out", output.path])) != nil
        else { return nil }
        return try? Data(contentsOf: output)
    }
}
