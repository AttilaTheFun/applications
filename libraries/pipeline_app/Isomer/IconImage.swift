import ImageIO

/// An app's icon as drawn in a row: on Isomer's platforms (Android, the
/// web) as it is. (The iPhone and
/// Mac trim a Mac icon's transparent margin in a CGContext bitmap, which
/// Isomer's CoreGraphics has not; a Mac icon's margin stays here.)
enum IconImage {
    nonisolated static func filling(_ image: CGImage) -> CGImage { image }
}
