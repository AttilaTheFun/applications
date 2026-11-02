import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A QR code of a string, written as a PNG: what the phone's camera scans
/// to open a link.
public enum QRImage {
    public static func write(_ text: String, to file: URL) throws {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CocoaError(.fileWriteUnknown) }
        // A white margin around it, as scanners like.
        let margin = code.extent.insetBy(dx: -48, dy: -48)
        let image = code.composited(over: CIImage(color: .white).cropped(to: margin))
        try CIContext().writePNGRepresentation(of: image, to: file, format: .RGBA8, colorSpace: space)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
