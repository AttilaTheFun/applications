import Foundation
@testable import ApplicationsServer

/// A small Android app made for a test: an .apk with a compiled
/// AndroidManifest.xml, a resources.arsc with its label (in two languages)
/// and its icon (two densities' PNGs and an adaptive icon's XML), the
/// PNGs, and — unless unsigned — an APK Signing Block (v2) whose one
/// certificate is `certificate`.
enum TestAPK {
    static let labelID: UInt32 = 0x7F01_0000
    static let iconID: UInt32 = 0x7F02_0000

    static func make(in folder: URL, package: String = "com.example.visor", label: String = "Visor", versionName: String = "0.31",
                     versionCode: UInt32 = 31, certificate: Data = Data("a test certificate".utf8), signed: Bool = true) throws -> URL {
        let work = folder.appendingPathComponent(UUID().uuidString)
        let files: [String: Data] = [
            "AndroidManifest.xml": manifest(package: package, versionName: versionName, versionCode: versionCode),
            "resources.arsc": resources(label: label),
            "res/mipmap-mdpi-v4/ic_launcher.png": Data("icon-mdpi".utf8),
            "res/mipmap-xxxhdpi-v4/ic_launcher.png": Data("icon-xxxhdpi".utf8),
            "res/mipmap-anydpi-v26/ic_launcher.xml": Data("<adaptive-icon/>".utf8),
        ]
        for (path, data) in files {
            let file = work.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        let output = folder.appendingPathComponent(UUID().uuidString + ".apk")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = work
        zip.arguments = ["-q", "-r", "-X", output.path] + files.keys.sorted()
        try zip.run()
        zip.waitUntilExit()
        if signed { try insertSigningBlock(into: output, certificate: certificate) }
        return output
    }

    // MARK: The signing block

    /// Puts a v2 signing block before the central directory, and moves
    /// the end record's offset of it past the block.
    static func insertSigningBlock(into apk: URL, certificate: Data) throws {
        var data = try Data(contentsOf: apk)
        let end = try endRecord(data)
        let directory = Int(data.uint32(at: end + 16) ?? 0)
        // Signed data: digests, certificates, attributes; then signatures and the public key.
        let signedData = prefixed(Data()) + prefixed(prefixed(certificate)) + prefixed(Data())
        let signer = prefixed(signedData) + prefixed(Data()) + prefixed(Data())
        let scheme = prefixed(prefixed(signer))
        let pair = little(UInt64(4 + scheme.count)) + little(UInt32(0x7109_871A)) + scheme
        let size = UInt64(pair.count + 8 + 16)
        let block = little(size) + pair + little(size) + Data("APK Sig Block 42".utf8)
        data.insert(contentsOf: block, at: directory)
        data.replaceSubrange(end + block.count + 16 ..< end + block.count + 20, with: little(UInt32(directory + block.count)))
        try data.write(to: apk)
    }

    /// Where the end of central directory record starts.
    private static func endRecord(_ data: Data) throws -> Int {
        guard let end = stride(from: data.count - 22, through: 0, by: -1).first(where: { data.uint32(at: $0) == 0x0605_4B50 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return end
    }

    // MARK: The manifest

    /// <manifest package versionCode versionName><application label icon/></manifest>,
    /// compiled: its strings (the attributes' names first, which the
    /// resource map gives their ids), then the elements.
    static func manifest(package: String, versionName: String, versionCode: UInt32) -> Data {
        let strings = ["versionCode", "versionName", "label", "icon", "package", "manifest", "application",
                       "http://schemas.android.com/apk/res/android", package, versionName]
        let android: UInt32 = 7
        let map = [0x0101_021B, 0x0101_021C, 0x0101_0001, 0x0101_0002].reduce(Data()) { $0 + little(UInt32($1)) }
        var body = stringPool(strings)
        body += chunk(type: 0x0180, header: Data(), body: map)
        body += startElement(name: 5, attributes: [
            (ns: 0xFFFF_FFFF, name: 4, raw: 8, type: 0x03, data: 8),
            (ns: android, name: 0, raw: 0xFFFF_FFFF, type: 0x10, data: versionCode),
            (ns: android, name: 1, raw: 9, type: 0x03, data: 9),
        ])
        body += startElement(name: 6, attributes: [
            (ns: android, name: 2, raw: 0xFFFF_FFFF, type: 0x01, data: labelID),
            (ns: android, name: 3, raw: 0xFFFF_FFFF, type: 0x01, data: iconID),
        ])
        body += chunk(type: 0x0103, header: little(UInt32(1)) + little(UInt32(0xFFFF_FFFF)), body: little(UInt32(0xFFFF_FFFF)) + little(UInt32(6)))
        body += chunk(type: 0x0103, header: little(UInt32(1)) + little(UInt32(0xFFFF_FFFF)), body: little(UInt32(0xFFFF_FFFF)) + little(UInt32(5)))
        return chunk(type: 0x0003, header: Data(), body: body)
    }

    private static func startElement(name: UInt32, attributes: [(ns: UInt32, name: UInt32, raw: UInt32, type: UInt8, data: UInt32)]) -> Data {
        var ext = little(UInt32(0xFFFF_FFFF)) + little(name) + little(UInt16(20)) + little(UInt16(20))
        ext += little(UInt16(attributes.count)) + little(UInt16(0)) + little(UInt16(0)) + little(UInt16(0))
        for attribute in attributes {
            ext += little(attribute.ns) + little(attribute.name) + little(attribute.raw)
            ext += little(UInt16(8)) + Data([0, attribute.type]) + little(attribute.data)
        }
        return chunk(type: 0x0102, header: little(UInt32(1)) + little(UInt32(0xFFFF_FFFF)), body: ext)
    }

    // MARK: The resources

    /// One package (0x7f) with a string type (1: the label, in French and
    /// in the default language) and a mipmap type (2: the icon, at mdpi,
    /// xxxhdpi and any density).
    static func resources(label: String) -> Data {
        let values = ["Visière", label, "res/mipmap-mdpi-v4/ic_launcher.png", "res/mipmap-xxxhdpi-v4/ic_launcher.png",
                      "res/mipmap-anydpi-v26/ic_launcher.xml"]
        var package = Data()
        package += type(1, language: "fr", density: 0, value: 0)
        package += type(1, language: "", density: 0, value: 1)
        package += type(2, language: "", density: 160, value: 2)
        package += type(2, language: "", density: 0xFFFE, value: 4)
        package += type(2, language: "", density: 640, value: 3)
        var packageHeader = little(UInt32(0x7F)) + Data(count: 256)
        packageHeader += little(UInt32(0)) + little(UInt32(0)) + little(UInt32(0)) + little(UInt32(0)) + little(UInt32(0))
        return chunk(type: 0x0002, header: little(UInt32(1)), body: stringPool(values) + chunk(type: 0x0200, header: packageHeader, body: package))
    }

    /// A type's one entry in one configuration: its value a string of the
    /// pool.
    private static func type(_ id: UInt8, language: String, density: UInt16, value: UInt32) -> Data {
        var config = little(UInt32(64)) + little(UInt32(0))
        config += language.isEmpty ? Data(count: 2) : Data(language.utf8.prefix(2))
        config += Data(count: 2) + Data([0, 0]) + little(density)
        config += Data(count: 64 - config.count)
        let headerSize = 8 + 12 + config.count
        let header = Data([id, 0]) + little(UInt16(0)) + little(UInt32(1)) + little(UInt32(headerSize + 4)) + config
        let entry = little(UInt16(8)) + little(UInt16(0)) + little(UInt32(0)) + little(UInt16(8)) + Data([0, 0x03]) + little(value)
        return chunk(type: 0x0201, header: header, body: little(UInt32(0)) + entry)
    }

    // MARK: Chunks

    /// A UTF-16 string pool.
    static func stringPool(_ strings: [String]) -> Data {
        var offsets = Data(), text = Data()
        for string in strings {
            offsets += little(UInt32(text.count))
            let units = Array(string.utf16)
            text += little(UInt16(units.count)) + units.reduce(Data()) { $0 + little($1) } + little(UInt16(0))
        }
        while text.count % 4 != 0 { text.append(0) }
        let header = little(UInt32(strings.count)) + little(UInt32(0)) + little(UInt32(0))
            + little(UInt32(28 + offsets.count)) + little(UInt32(0))
        return chunk(type: 0x0001, header: header, body: offsets + text)
    }

    /// A chunk: its type, its header's size, its size, the rest of its
    /// header, its body.
    static func chunk(type: UInt16, header: Data, body: Data) -> Data {
        little(type) + little(UInt16(8 + header.count)) + little(UInt32(8 + header.count + body.count)) + header + body
    }

    static func prefixed(_ data: Data) -> Data { little(UInt32(data.count)) + data }

    static func little<Value: FixedWidthInteger>(_ value: Value) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
