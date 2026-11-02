import CoreGraphics

/// An app's icon as the lists draw it: a Mac app's icon sits inside a
/// transparent margin (with its shadow) and an iPhone app's reaches the
/// edges, so the margin is cut away and every icon fills its square alike.
enum IconImage {
    nonisolated static func filling(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return image }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }
        // The icon itself: nearly opaque, where its shadow is mostly not.
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 200 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        // A square about the icon's middle, so its shape stays as drawn;
        // one that reaches the edges already is kept whole.
        let side = max(maxX - minX + 1, maxY - minY + 1)
        guard side * 100 < width * 97 else { return image }
        let x = max(0, (minX + maxX + 1 - side) / 2), y = max(0, (minY + maxY + 1 - side) / 2)
        return image.cropping(to: CGRect(x: x, y: y, width: min(side, width - x), height: min(side, height - y))) ?? image
    }
}
