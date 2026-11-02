import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// A picture compared with the one kept for it: the same size, and no more
/// than a few pixels apart (by more than a little, in any channel), so
/// fonts drawn a hair differently pass and a moved title does not. With
/// SNAPSHOT_RECORD_DIR set, the picture is kept there instead (the folder
/// the kept pictures live in), and the test says so. Either way the picture
/// is attached to the test's results under its name, kept whether the test
/// passes or not: where the tests run on an iOS lease (`oss machine xctest`),
/// which takes no environment, the proof's screens come from the result
/// bundle's attachments (tools/ci/ios_lease_tests.sh).
public enum Snapshot {
    /// `kept`: the kept picture's file, where the test finds it (an iOS
    /// test's bundle, a Mac test's runfiles); nil when there is none.
    public static func check(_ image: CGImage, named name: String, kept: URL?, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual = png(image) else { return XCTFail("no picture", file: file, line: line) }
        attach(actual, named: name)
        if let folder = ProcessInfo.processInfo.environment["SNAPSHOT_RECORD_DIR"], !folder.isEmpty {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")
            do {
                try actual.write(to: url)
                XCTFail("Recorded \(name) at \(url.path): run again without SNAPSHOT_RECORD_DIR to compare", file: file, line: line)
            } catch {
                XCTFail("Could not record \(name): \(error)", file: file, line: line)
            }
            return
        }
        guard let kept, let data = try? Data(contentsOf: kept), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let keptImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("No kept picture \(name).png: record it (SNAPSHOT_RECORD_DIR)", file: file, line: line)
        }
        let difference = differing(keptImage, image)
        if difference > 0.004 {
            if let outputs = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] {
                try? actual.write(to: URL(fileURLWithPath: outputs).appendingPathComponent(name + "-actual.png"))
            }
            XCTFail("\(name) differs from its kept picture in \(Int(difference * 1000) / 10)% of its pixels", file: file, line: line)
        }
    }

    /// The picture attached to the test's results as `<name>.png`, kept
    /// whether the test passes or not. XCTest attaches on the main thread,
    /// where a screen's test takes its picture; off it, nothing is attached.
    private static func attach(_ png: Data, named name: String) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            XCTContext.runActivity(named: "Snapshot \(name)") { activity in
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: UTType.png.identifier)
                attachment.name = name + ".png"
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
    }

    /// The share of pixels that differ by more than a little (1 where the
    /// sizes differ).
    public static func differing(_ a: CGImage, _ b: CGImage) -> Double {
        guard let left = rgba(a), let right = rgba(b), left.width == right.width, left.height == right.height else { return 1 }
        var count = 0
        for index in stride(from: 0, to: left.bytes.count, by: 4) {
            for channel in 0..<3 where abs(Int(left.bytes[index + channel]) - Int(right.bytes[index + channel])) > 24 {
                count += 1
                break
            }
        }
        return Double(count) / Double(left.width * left.height)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func rgba(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (bytes, width, height) : nil
    }
}
